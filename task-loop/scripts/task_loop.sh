#!/usr/bin/env bash
#
# task_loop.sh - Task loop orchestrator for Kilo CLI with Review Gate
#
# Использование:
#   ./task_loop.sh --tasks-path PATH [--max-iterations N] [--verbose] [--no-review] [--no-commit] [--working-directory DIR]
#
# Конфигурация:
#   --tasks-path PATH        Путь к tasks.md (обязательно)
#   --max-iterations N       Максимум итераций (по умолчанию: 50, диапазон: 1-1000)
#   --verbose                Подробный вывод
#   --no-review              Отключить review gate (для hotfix)
#   --no-commit              Отключить git commit (для тестирования)
#   --working-directory DIR  Рабочая директория
#
# Возможности:
#   - Одна задача за итерацию с обязательным review
#   - Мульти-агентное review перед отметкой задачи выполненной
#   - Circuit breaker: остановка после 3 последовательных неудач
#   - Retry при инфраструктурном сбое review: до 2 попыток (если kilo не создал result file), затем escalation
#   - Exponential backoff при неудачах (макс 60с)
#   - Информативный вывод с временными метками
#

set -euo pipefail

umask 077

#region Константы
readonly MAX_CONSECUTIVE_FAILURES=3
readonly MAX_TASK_REJECTIONS=5
readonly MAX_BACKOFF_SECONDS=60
readonly MAX_TOTAL_ATTEMPTS_MULTIPLIER=10
readonly DEFAULT_MAX_ITERATIONS=50
readonly MIN_ITERATIONS=1
readonly MAX_ITERATIONS_LIMIT=1000
readonly PENDING_GRACE_SECONDS=30
#endregion

#region Конфигурация
TASKS_PATH=""
MAX_ITERATIONS=$DEFAULT_MAX_ITERATIONS
VERBOSE=false
NO_REVIEW=false
NO_COMMIT=false
WORKING_DIRECTORY=""
PROJECT_ROOT=""
PROMPT_FILE=".kilo/prompts/task-iterate.md"
REVIEW_PROMPT_FILE=".kilo/prompts/task-review.md"
LOG_FILE=""
STATE_FILE=""
PENDING_TASKS_FILE=""
FRONTMATTER_CACHE_FILE=""
REVIEW_RESULT_FILE=""

# DI для тестирования
KILO_CMD="${KILO_CMD:-kilo}"
GIT_CMD="${GIT_CMD:-git}"
SLEEP_CMD="${SLEEP_CMD:-sleep}"
#endregion

#region Функции для работы с dependencies
parse_frontmatter_deps() {
    local task_file="$1"
    
    if [[ ! -f "$task_file" ]]; then
        echo ""
        return 1
    fi
    
    grep '^dependencies:' "$task_file" 2>/dev/null | \
        sed -n 's/^dependencies: \[\(.*\)\]/\1/p' | \
        tr -d ' ' | tr ',' '\n' | \
        grep -E '^T[0-9]+$' || echo ""
}

is_task_completed() {
    local task_id="$1"
    local tasks_file="$2"
    
    grep -qE "^\s*-\s*\[x\]\s+${task_id}" "$tasks_file" 2>/dev/null
}

atomic_write() {
    local file="$1"
    local content="$2"
    local tmp_file="${file}.tmp.$$"
    
    if printf '%s\n' "$content" > "$tmp_file" && mv "$tmp_file" "$file"; then
        return 0
    else
        rm -f "$tmp_file" 2>/dev/null
        return 1
    fi
}

check_dependencies() {
    local task_file="$1"
    local tasks_file="$2"
    
    local deps
    deps=$(parse_frontmatter_deps "$task_file")
    
    [[ -z "$deps" ]] && return 0
    
    for dep in $deps; do
        if ! is_task_completed "$dep" "$tasks_file"; then
            return 1
        fi
    done
    
    return 0
}

validate_tasks_integrity() {
    local tasks_file="$1"
    local tasks_dir="$2"
    local errors=0
    
    while IFS= read -r line; do
        if [[ $line =~ ^-\ \[\ \]\ .*(T[0-9]+) ]]; then
            local task_id="${BASH_REMATCH[1]}"
            if [[ ! -f "$tasks_dir/${task_id}.md" ]]; then
                echo "ERROR: Missing task file for $task_id" >&2
                ((errors++))
            fi
        fi
    done < "$tasks_file"
    
    if [[ -d "$tasks_dir" ]]; then
        detect_dependency_cycles "$tasks_file" "$tasks_dir"
        local cycle_result=$?
        if [[ $cycle_result -ne 0 ]]; then
            ((errors++))
        fi
    fi
    
    return $errors
}

detect_dependency_cycles() {
    local tasks_file="$1"
    local tasks_dir="$2"
    
    local dep_graph_file
    dep_graph_file=$(mktemp)
    
    while IFS= read -r line; do
        if [[ $line =~ ^-\ \[\ \]\ .*(T[0-9]+) ]]; then
            local task_id="${BASH_REMATCH[1]}"
            local task_file="$tasks_dir/${task_id}.md"
            
            if [[ -f "$task_file" ]]; then
                local deps
                deps=$(parse_frontmatter_deps "$task_file")
                if [[ -n "$deps" ]]; then
                    for dep in $deps; do
                        echo "${task_id} ${dep}" >> "$dep_graph_file"
                    done
                fi
            fi
        fi
    done < "$tasks_file"
    
    local all_task_ids
    all_task_ids=$(grep -oE 'T[0-9]+' "$dep_graph_file" 2>/dev/null | sort -u || echo "")
    
    local visited_list=""
    local visiting_list=""
    local cycle_found=0
    
    _check_cycle() {
        local task="$1"
        local path="$2"
        
        if echo " $visiting_list " | grep -q " $task "; then
            print_status "error" "Cyclic dependency detected: $path -> $task"
            return 1
        fi
        
        if echo " $visited_list " | grep -q " $task "; then
            return 0
        fi
        
        visiting_list="$visiting_list $task"
        
        local deps
        deps=$(grep "^${task} " "$dep_graph_file" 2>/dev/null | awk '{print $2}' || echo "")
        
        if [[ -n "$deps" ]]; then
            for dep in $deps; do
                if ! _check_cycle "$dep" "$path -> $task"; then
                    return 1
                fi
            done
        fi
        
        visiting_list=$(echo " $visiting_list " | sed "s/ $task / /" | sed 's/^ //;s/ $//')
        visited_list="$visited_list $task"
        return 0
    }
    
    for tid in $all_task_ids; do
        if ! echo " $visited_list " | grep -q " $tid "; then
            if ! _check_cycle "$tid" ""; then
                cycle_found=1
                break
            fi
        fi
    done
    
    rm -f "$dep_graph_file"
    return $cycle_found
}
#endregion

#region Функции безопасности
validate_path() {
    local path="$1"
    local description="$2"
    
    if [[ ! -e "$path" ]]; then
        echo "Ошибка: $description не найден: $path" >&2
        return 1
    fi
    
    path=$(realpath "$path")
    local project_root_real
    project_root_real=$(realpath "$PROJECT_ROOT")
    
    if [[ ! "$path" =~ ^"$project_root_real" ]]; then
        echo "Ошибка: Обнаружен path traversal. $description должен быть внутри директории проекта" >&2
        return 1
    fi
    
    echo "$path"
}

validate_numeric() {
    local value="$1"
    local name="$2"
    local min="$3"
    local max="$4"
    
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "Ошибка: $name должен быть положительным целым числом" >&2
        return 1
    fi
    
    if [[ $value -lt $min || $value -gt $max ]]; then
        echo "Ошибка: $name должен быть между $min и $max" >&2
        return 1
    fi
}

parse_frontmatter_decision() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        echo ""
        return 1
    fi
    
    sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null | \
        sed '1d;$d' | \
        grep "^decision:" | \
        head -1 | \
        cut -d: -f2 | \
        tr -d ' "'
}
#endregion

#region Парсинг аргументов
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tasks-path)
                if [[ -z "${2:-}" ]]; then
                    echo "Ошибка: --tasks-path требует значение" >&2
                    return 1
                fi
                TASKS_PATH="$2"
                shift 2
                ;;
            --max-iterations)
                if [[ -z "${2:-}" ]]; then
                    echo "Ошибка: --max-iterations требует значение" >&2
                    return 1
                fi
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --no-review)
                NO_REVIEW=true
                shift
                ;;
            --no-commit)
                NO_COMMIT=true
                shift
                ;;
            --working-directory)
                if [[ -z "${2:-}" ]]; then
                    echo "Ошибка: --working-directory требует значение" >&2
                    return 1
                fi
                WORKING_DIRECTORY="$2"
                shift 2
                ;;
            --help|-h)
                echo "Использование: $0 --tasks-path PATH [--max-iterations N] [--verbose] [--no-review] [--no-commit] [--working-directory DIR]"
                echo ""
                echo "Параметры:"
                echo "  --tasks-path PATH        Путь к tasks.md (обязательно)"
                echo "  --max-iterations N       Максимум итераций (по умолчанию: 50)"
                echo "  --verbose                Подробный вывод"
                echo "  --no-review              Отключить review gate"
                echo "  --no-commit              Отключить git commit"
                echo "  --working-directory DIR  Рабочая директория"
                return 0
                ;;
            --force)
                echo "Ошибка: --force удалён. Lock-механика больше не поддерживается." >&2
                echo "Не запускайте несколько экземпляров параллельно." >&2
                return 1
                ;;
            *)
                echo "Ошибка: Неизвестный параметр: $1" >&2
                return 1
                ;;
        esac
    done
}
#endregion

#region Вспомогательные функции
print_header() {
    local iteration=$1
    local max=$2
    echo "========================================================"
    echo "🔄 Итерация $iteration/$max — $(date +'%H:%M:%S')"
    echo "========================================================"
}

format_timestamp() {
    date +'%H:%M:%S'
}

print_phase() {
    local phase=$1
    local message=$2
    local ts
    ts=$(format_timestamp)
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "[$ts] $phase: $message"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

print_status() {
    local status=$1
    local message=$2
    local ts
    ts=$(format_timestamp)
    local icon=""
    
    case "$status" in
        success) icon="✅" ;;
        failure) icon="⚠️ " ;;
        error)   icon="❌" ;;
        info)    icon="ℹ️ " ;;
    esac
    
    echo "[$ts] $icon $message"
}

log_message() {
    local level=$1
    local message=$2
    local ts
    ts=$(format_timestamp)
    echo "[$ts] [$level] $message"
}

get_incomplete_task_count() {
    local tasks_file="$1"
    local count=0
    
    if [[ -f "$tasks_file" ]]; then
        count=$(grep -c "^\s*-\s*\[ \]" "$tasks_file" 2>/dev/null || echo "0")
        count=$(echo "$count" | tr -d '[:space:]')
    fi
    
    echo "${count:-0}"
}

get_first_incomplete_task() {
    local tasks_file="$1"
    grep -m 1 "^\s*-\s*\[ \]" "$tasks_file" 2>/dev/null | grep -oE '[A-Z]+-[0-9]+|T[0-9]+' | head -1 || echo ""
}

get_next_executable_task() {
    local tasks_file="$1"
    local tasks_dir="$2"
    
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^\s*-\s*\[ \]\s+[A-Z0-9-]+'; then
            local task_id=$(echo "$line" | grep -oE '[A-Z]+-[0-9]+|T[0-9]+' | head -1)
            
            local task_file="$tasks_dir/${task_id}.md"
            
            if [[ ! -f "$task_file" ]]; then
                print_status "failure" "Файл задачи не найден: $task_file"
                continue
            fi
            
            if check_dependencies "$task_file" "$tasks_file"; then
                echo "$task_id"
                return 0
            fi
        fi
    done < "$tasks_file"
    
    echo ""
}

mark_task_completed() {
    local tasks_file="$1"
    local task_id="$2"
    
    if [[ -z "$task_id" ]]; then
        return 1
    fi
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/- \[ \] ${task_id}/- [x] ${task_id}/" "$tasks_file"
    else
        sed -i "s/- \[ \] ${task_id}/- [x] ${task_id}/" "$tasks_file"
    fi
    
    print_status "success" "Задача $task_id помечена как выполненная"
}

print_summary() {
    local tasks_completed=$1
    local status=$2
    local total_attempts=${3:-0}
    echo ""
    echo "========================================================"
    echo "  Task Loop — Сводка"
    echo "========================================================"
    echo "  Задач выполнено: $tasks_completed"
    echo "  Всего попыток: $total_attempts"
    echo "  Итераций (повторные попытки): $iteration"
    echo "  Статус: $status"
    echo "  Лог файл: $LOG_FILE"
    echo "  Review включён: $(if [[ "$NO_REVIEW" == "true" ]]; then echo "НЕТ"; else echo "ДА"; fi)"
    echo "========================================================"
}

calculate_backoff() {
    local failure_count=$1
    local backoff=$((2 ** failure_count))
    [[ $backoff -gt $MAX_BACKOFF_SECONDS ]] && backoff=$MAX_BACKOFF_SECONDS
    echo "$backoff"
}

handle_failure() {
    local failure_type="$1"
    local failure_count="$2"
    local max_failures="$3"
    local exit_status="$4"
    
    ((failure_count++))
    
    print_status "failure" "Неудача $failure_type: $failure_count/$max_failures" >&2
    
    if [[ $failure_count -ge $max_failures ]]; then
        print_status "error" "Circuit breaker сработал" >&2
        print_summary "$tasks_completed" "$exit_status" "$total_attempts" >&2
        echo "CIRCUIT_BREAKER"
        return 0
    fi
    
    local backoff
    backoff=$(calculate_backoff "$failure_count")
    echo "⏳ Ожидание ${backoff}с перед повторной попыткой..." >&2
    $SLEEP_CMD "$backoff"
    
    echo "$failure_count"
}
#endregion

#region Функции управления состоянием
save_state() {
    local state="$1"
    local iteration="$2"
    local current_task="$3"
    local _empty_json='{}'
    
    local json_content=$(cat << STATE_JSON
{
  "state": "$state",
  "iteration": $iteration,
  "current_task": "$current_task",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pid": $$,
  "coordinator_session_id": "${coordinator_session_id:-}",
  "review_retries": ${review_retries:-0},
  "tasks_completed": ${tasks_completed:-0},
  "total_attempts": ${total_attempts:-0},
  "failed_tasks": $(echo "${failed_tasks:-[]}" | jq -c . 2>/dev/null || echo "[]"),
  "consecutive_failures": ${consecutive_failures:-0},
  "impl_failures": ${impl_failures:-0},
  "infra_failures": ${infra_failures:-0},
  "task_rejection_counts": $(echo "${task_rejection_counts:-$_empty_json}" | jq -c . 2>/dev/null || echo "{}")
}
STATE_JSON
)
    printf '%s\n' "$json_content" > "${STATE_FILE}.tmp.$$" && mv "${STATE_FILE}.tmp.$$" "$STATE_FILE"
}

load_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return 0
    fi
    
    if [[ ! -s "$STATE_FILE" ]]; then
        return 0
    fi
    
    if ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
        print_status "warning" "State file повреждён, запуск с чистого состояния"
        return 0
    fi
    
    local saved_state
    saved_state=$(jq -r '.state // empty' "$STATE_FILE" 2>/dev/null)
    local saved_iteration
    saved_iteration=$(jq -r '.iteration // 0' "$STATE_FILE" 2>/dev/null)
    local saved_review_retries
    saved_review_retries=$(jq -r '.review_retries // 0' "$STATE_FILE" 2>/dev/null)
    local saved_tasks_completed
    saved_tasks_completed=$(jq -r '.tasks_completed // 0' "$STATE_FILE" 2>/dev/null)
    local saved_total_attempts
    saved_total_attempts=$(jq -r '.total_attempts // 0' "$STATE_FILE" 2>/dev/null)
    local saved_consecutive_failures
    saved_consecutive_failures=$(jq -r '.consecutive_failures // 0' "$STATE_FILE" 2>/dev/null)
    local saved_impl_failures
    saved_impl_failures=$(jq -r '.impl_failures // 0' "$STATE_FILE" 2>/dev/null)
    local saved_infra_failures
    saved_infra_failures=$(jq -r '.infra_failures // 0' "$STATE_FILE" 2>/dev/null)
    local saved_failed_tasks
    saved_failed_tasks=$(jq -r '.failed_tasks // []' "$STATE_FILE" 2>/dev/null)
    local saved_rejection_counts
    saved_rejection_counts=$(jq -r '.task_rejection_counts // {}' "$STATE_FILE" 2>/dev/null)
    local saved_current_task
    saved_current_task=$(jq -r '.current_task // empty' "$STATE_FILE" 2>/dev/null)
    local saved_coordinator_sid
    saved_coordinator_sid=$(jq -r '.coordinator_session_id // ""' "$STATE_FILE" 2>/dev/null)
    
    iteration=${saved_iteration:-0}
    review_retries=${saved_review_retries:-0}
    tasks_completed=${saved_tasks_completed:-0}
    total_attempts=${saved_total_attempts:-0}
    consecutive_failures=${saved_consecutive_failures:-0}
    impl_failures=${saved_impl_failures:-0}
    infra_failures=${saved_infra_failures:-0}
    failed_tasks="${saved_failed_tasks:-[]}"
    local _empty_json='{}'
    task_rejection_counts="${saved_rejection_counts:-$_empty_json}"
    
    if [[ -n "$saved_coordinator_sid" ]]; then
        coordinator_session_id="$saved_coordinator_sid"
        print_status "info" "Восстановлена coordinator session: $coordinator_session_id"
    elif [[ -n "$saved_current_task" ]] && [[ "$saved_state" == "REJECTED" ]]; then
        local fb_feature
        fb_feature=$(extract_feature_name "$TASKS_PATH" 2>/dev/null || echo "unknown")
        local fb_title
        fb_title=$(sanitize_session_title "review-${fb_feature}-${saved_current_task}-*")
        coordinator_session_id=$(extract_coordinator_session_id "$fb_title" 3 2 2>/dev/null || echo "")
        if [[ -n "$coordinator_session_id" ]]; then
            print_status "info" "Восстановлена coordinator session (fallback): $coordinator_session_id"
        else
            print_status "info" "Coordinator session не найдена — будет создана новая"
        fi
    fi
    
    print_status "info" "Восстановление состояния: iteration=$iteration, tasks_completed=$tasks_completed, consecutive_failures=$consecutive_failures"
    
    if [[ "$saved_state" == "REJECTED" ]]; then
        print_status "info" "Предыдущая задача была REJECTED — будет продолжена"
    elif [[ "$saved_state" == "FAILED" ]]; then
        print_status "warning" "Предыдущая итерация завершилась с ошибкой"
    fi
}
#endregion

#region Функции Review Gate
run_review_gate() {
    local iteration=$1
    local task_id=$2
    local pending_file=$3
    local task_file_path=$4
    
    if [[ "$NO_REVIEW" == "true" ]]; then
        print_status "info" "Review gate отключён (--no-review)"
        return 0
    fi
    
    print_phase "ФАЗА 2: Review Gate" "Проверка задачи $task_id"
    
    rm -f "$REVIEW_RESULT_FILE"
    
    local safe_tasks_path=$(printf '%s' "$TASKS_PATH" | sed 's/[&/\]/\\&/g')
    local safe_pending_file=$(printf '%s' "$pending_file" | sed 's/[&/\]/\\&/g')
    local safe_review_result=$(printf '%s' "$REVIEW_RESULT_FILE" | sed 's/[&/\]/\\&/g')
    local safe_task_file_path=$(printf '%s' "$task_file_path" | sed 's/[&/\]/\\&/g')
    
    local PRD_PATH="${FEATURE_DIR}/PRD.md"
    local safe_prd_path=""
    if [[ -f "$PRD_PATH" ]]; then
        safe_prd_path=$(printf '%s' "$PRD_PATH" | sed 's/[&/\]/\\&/g')
    fi
    
    local PROMPT=$(sed "s|\$TASKS_PATH|$safe_tasks_path|g" "$REVIEW_PROMPT_FILE")
    PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$safe_pending_file|g" <<< "$PROMPT")
    PROMPT=$(sed "s|\$REVIEW_RESULT_FILE|$safe_review_result|g" <<< "$PROMPT")
    PROMPT=$(sed "s|\$TASK_FILE_PATH|$safe_task_file_path|g" <<< "$PROMPT")
    PROMPT=$(sed "s|\$PRD_PATH|$safe_prd_path|g" <<< "$PROMPT")
    
    local feature_name
    feature_name=$(extract_feature_name "$TASKS_PATH")
    local session_title
    session_title=$(sanitize_session_title "review-${feature_name}-${task_id}-$$")
    
    set +e
    if [[ -n "${coordinator_session_id:-}" ]]; then
        run_kilo_with_sentinel "review-$task_id" "$PROMPT" "$REVIEW_RESULT_FILE" "$PENDING_GRACE_SECONDS" "continue:$coordinator_session_id"
    else
        run_kilo_with_sentinel "review-$task_id" "$PROMPT" "$REVIEW_RESULT_FILE" "$PENDING_GRACE_SECONDS" "new:$session_title"
    fi
    local exit_code=$?
    
    if [[ -z "$coordinator_session_id" ]] && [[ -f "$REVIEW_RESULT_FILE" ]]; then
        local sid
        sid=$(extract_coordinator_session_id "$session_title")
        if [[ -n "$sid" ]]; then
            coordinator_session_id="$sid"
            print_status "info" "Coordinator session: $coordinator_session_id"
        fi
    fi
    # Do NOT re-enable errexit here — the caller manages it.
    # Re-enabling errexit inside this function causes return 1 to kill the script
    # even though the caller did set +e before calling us.
    
    if [[ ! -f "$REVIEW_RESULT_FILE" ]]; then
        ((review_retries++))
        
        if [[ $review_retries -ge 2 ]]; then
            print_status "error" "Review failed after $review_retries retries"
            mark_task_failed "$task_id"
            create_escalation_for_review_failure "$task_id"
            return 2
        fi
        
        print_status "warning" "Review result not found, retrying ($review_retries/2)"
        return 1
    fi
    
    local decision
    decision=$(parse_frontmatter_decision "$REVIEW_RESULT_FILE")
    
    if [[ "$decision" == "APPROVED" ]]; then
        print_status "success" "Review ПРОЙДЕН — Задача $task_id одобрена"
        echo ""
        review_retries=0
        return 0
        
    elif [[ "$decision" == "REJECTED" ]]; then
        print_status "error" "Review ОТКЛОНЁН — Задаче $task_id требуются исправления"
        echo ""
        print_status "info" "Исправления описаны в: $REVIEW_RESULT_FILE"
        review_retries=0
        return 1
        
    else
        print_status "error" "Некорректный decision в review result: '$decision'"
        print_status "info" "Файл: $REVIEW_RESULT_FILE"
        return 2
    fi
}

mark_task_failed() {
    local task_id="$1"
    
    if [[ -z "$failed_tasks" ]]; then
        failed_tasks='["'$task_id'"]'
    else
        failed_tasks=$(echo "$failed_tasks" | jq --arg t "$task_id" '. + [$t]' 2>/dev/null)
    fi
    
    ((consecutive_failures++))
}

create_escalation_for_review_failure() {
    local task_id="$1"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    cat > "${FEATURE_DIR}/.escalation_handoff.md" <<EOF
# Escalation: Review Coordinator Failure

**Task ID:** $task_id
**Timestamp:** $timestamp
**Severity:** BLOCKER

## Problem

Review coordinator failed to create result file after $review_retries attempts.

## Required Actions

1. Review coordinator logs for errors
2. Check if review coordinator prompt is correct
3. Verify Kilo daemon is running
4. Check disk space and permissions in $FEATURE_DIR

## State

- Iteration: $iteration
- Consecutive failures: $consecutive_failures
- Failed tasks: ${failed_tasks:-[]}
EOF
    
    print_status "info" "Escalation created: ${FEATURE_DIR}/.escalation_handoff.md"
}

# =====================================================
# GENERIC KILO EXECUTION WITH SENTINEL FILE DETECTION
# =====================================================
# Launches kilo in background, monitors for a sentinel file,
# and kills kilo once sentinel appears (with grace period).
# This prevents hanging when model finishes work but doesn't exit.
# Works with any sentinel file — pending tasks or review result.

_monitor_kilo() {
    local kilo_pid=$1
    local sentinel_file=$2
    local grace_seconds=$3
    local task_id=$4
    local kilo_exit_code_var=$5

    if [[ -z "$kilo_exit_code_var" ]]; then
        log_message "ERROR" "printf -v target variable name is empty in _monitor_kilo"
        return 1
    fi

    if ! kill -0 $kilo_pid 2>/dev/null; then
        wait $kilo_pid 2>/dev/null; local rc=$?; true
        printf -v "$kilo_exit_code_var" '%s' "$rc"
        log_message "INFO" "Kilo exited on its own for task $task_id (exit code: $rc)"
        return 0
    fi

    if [[ -n "$sentinel_file" && -f "$sentinel_file" ]]; then
        log_message "INFO" "Sentinel file detected for task $task_id — waiting ${grace_seconds}s before kill"

        local deadline=$(($(date +%s) + grace_seconds))
        while [[ $(date +%s) -lt $deadline ]]; do
            $SLEEP_CMD 0.5
            if ! kill -0 $kilo_pid 2>/dev/null; then
                wait $kilo_pid 2>/dev/null; local rc=$?; true
                printf -v "$kilo_exit_code_var" '%s' "$rc"
                log_message "INFO" "Kilo exited on its own during grace period for task $task_id (exit code: $rc)"
                return 0
            fi
        done

        log_message "INFO" "Grace period expired — killing Kilo (PID: $kilo_pid)"
        kill $kilo_pid 2>/dev/null || true
        wait $kilo_pid 2>/dev/null; local rc=$?; true
        printf -v "$kilo_exit_code_var" '%s' "0"
        log_message "INFO" "Kilo stopped after sentinel file was created"
        return 0
    fi

    return 1
}

run_kilo_with_sentinel() {
    local task_id="$1"
    local prompt="$2"
    local sentinel_file="$3"
    local grace_seconds="${4:-$PENDING_GRACE_SECONDS}"
    local session_mode="${5:-}"

    log_message "INFO" "Starting Kilo for task $task_id (background monitoring enabled)"

    local kilo_bin="$KILO_CMD"
    if [[ -n "$sentinel_file" ]]; then
        rm -f "$sentinel_file"
    fi

    if [[ "$session_mode" =~ ^continue: ]]; then
        local sid="${session_mode#continue:}"
        $kilo_bin run --auto --continue --session "$sid" "$prompt" &
    elif [[ "$session_mode" =~ ^new: ]]; then
        local title="${session_mode#new:}"
        $kilo_bin run --auto --title "$title" "$prompt" &
    else
        $kilo_bin run --auto "$prompt" &
    fi

    local kilo_pid=$!

    log_message "INFO" "Kilo PID: $kilo_pid, monitoring for $sentinel_file..."

    local kilo_exit_code=0

    while true; do
        if _monitor_kilo "$kilo_pid" "$sentinel_file" "$grace_seconds" "$task_id" kilo_exit_code; then
            return $kilo_exit_code
        fi

        if [[ -n "$sentinel_file" && -f "$sentinel_file" ]]; then
            _monitor_kilo "$kilo_pid" "$sentinel_file" "0" "$task_id" kilo_exit_code
            return $kilo_exit_code
        fi

        sleep 2
    done
}

do_commit() {
    local feature_name="$1"
    local task_id="$2"
    local iteration="$3"
    
    echo ""
    print_phase "ФАЗА 3: Коммит" "Создание git коммита для $task_id"
    
    local safe_feature_name=$(printf '%s' "$feature_name" | sed 's/[^a-zA-Z0-9_-]/_/g')
    local commit_message="feat(${safe_feature_name}): ${task_id}"
    
    if [[ "$NO_REVIEW" != "true" ]]; then
        commit_message="${commit_message}

Review: ✅ ПРОЙДЕН"
    fi
    
    $GIT_CMD add -A
    $GIT_CMD commit -m "$commit_message"
    
    print_status "success" "Закоммичено: $commit_message"
}

extract_feature_name() {
    local tasks_path="$1"
    local dirname=$(dirname "$tasks_path")
    local basename=$(basename "$dirname")
    echo "$basename"
}

sanitize_session_title() {
    local raw="$1"
    echo "$raw" | sed 's/[^a-zA-Z0-9._-]/_/g'
}

extract_coordinator_session_id() {
    local session_title="$1"
    local max_attempts="${2:-3}"
    local sleep_seconds="${3:-2}"
    local attempt=1

    if ! command -v jq >/dev/null 2>&1; then
        print_status "error" "jq required for coordinator session lookup"
        echo ""
        return 1
    fi

    while [[ $attempt -le $max_attempts ]]; do
        local session_json
        session_json=$(timeout 5 $KILO_CMD session list --format json --search "$session_title" --max-count 1 2>/dev/null)
        local sid
        sid=$(echo "$session_json" | jq -r '.[0].id // empty' 2>/dev/null)
        if [[ -n "$sid" ]]; then
            echo "$sid"
            return 0
        fi
        if [[ $attempt -lt $max_attempts ]]; then
            $SLEEP_CMD "$sleep_seconds"
        fi
        ((attempt++))
    done
    print_status "warning" "Coordinator session not found after $max_attempts attempts (title: $session_title)"
    echo ""
    return 1
}
#endregion

#region Функции конфигурации build/test gate (.kilo/task_loop.yaml)
read_task_loop_config() {
    local config_file="${PROJECT_ROOT}/.kilo/task_loop.yaml"
    
    if [[ ! -f "$config_file" ]]; then
        print_status "info" "Конфиг .kilo/task_loop.yaml не найден"
        return 1
    fi
    
    # Extract build_command: "value" (double quotes)
    BUILD_COMMAND=$(sed -n 's/^build_command: *"\(.*\)"/\1/p' "$config_file" | head -1)
    
    # Fallback: build_command: 'value' (single quotes)
    if [[ -z "$BUILD_COMMAND" ]]; then
        BUILD_COMMAND=$(sed -n "s/^build_command: *'\(.*\)'/\1/p" "$config_file" | head -1)
    fi
    
    # Fallback: build_command: value (unquoted, strip inline comments)
    if [[ -z "$BUILD_COMMAND" ]]; then
        BUILD_COMMAND=$(sed -n 's/^build_command: *\([^#]*\).*/\1/p' "$config_file" | head -1 | sed 's/^ *//;s/ *$//')
    fi
    
    # Same for test_command
    TEST_COMMAND=$(sed -n 's/^test_command: *"\(.*\)"/\1/p' "$config_file" | head -1)
    
    if [[ -z "$TEST_COMMAND" ]]; then
        TEST_COMMAND=$(sed -n "s/^test_command: *'\(.*\)'/\1/p" "$config_file" | head -1)
    fi
    
    # Handle explicit null
    if grep -q '^test_command: *null' "$config_file" 2>/dev/null; then
        TEST_COMMAND=""
    fi
    
    return 0
}

print_config_instruction() {
    local project_root="$1"
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║   .kilo/task_loop.yaml не найден                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Чтобы включить автоматическую проверку сборки и тестов,"
    echo "создай файл .kilo/task_loop.yaml со следующим содержимым:"
    echo ""
    echo "  build_command: \"dotnet build <solution-name>.sln\""
    echo "  test_command: \"dotnet test <solution-name>.sln\""
    echo ""
    echo "Инструкция для агента:"
    echo "  1. Найди .sln файл в корне проекта"
    echo "  2. Создай .kilo/task_loop.yaml с build_command и test_command"
    echo "  3. Если тесты не нужны (фронтенд без тестов), укажи test_command: null"
    echo ""
    echo "Примеры:"
    echo "  .NET с солюшеном:"
    echo "    build_command: \"dotnet build MyApp.sln\""
    echo "    test_command: \"dotnet test MyApp.sln\""
    echo ""
    echo "  Фронтенд без тестов:"
    echo "    build_command: \"npm run build\""
    echo "    test_command: null"
    echo ""
    echo "Путь: ${project_root}/.kilo/task_loop.yaml"
}

execute_gate_command() {
    local cmd="$1"
    local timeout_seconds="${2:-300}"
    local description="${3:-command}"
    
    # Validate: extract first word (base command) and check whitelist
    local base_cmd
    base_cmd=$(echo "$cmd" | sed 's/ .*//')
    case "$base_cmd" in
        dotnet|npm|npx|make|cargo|go|pytest|gradle|mvn|node) ;;
        *)
            print_status "error" "Недопустимая команда: '$base_cmd'"
            return 1
            ;;
    esac
    
    # Validate entire command string: only safe characters allowed
    # Safe: alphanumeric, space, /, ., -, _, :, =, @
    # grep pattern: - at end to avoid macOS range issue
    if echo "$cmd" | grep -q '[^][a-zA-Z0-9 /._:@=-]'; then
        print_status "error" "Команда содержит недопустимые символы (; | $ \` {} () < > ! \ и др.)"
        print_status "error" "Команда: $cmd"
        return 1
    fi
    
    if [[ -n "$timeout_cmd" ]]; then
        print_status "info" "Выполнение $description: $cmd (timeout: ${timeout_seconds}s)"
    else
        print_status "info" "Выполнение $description: $cmd (без таймаута)"
    fi
    set +e
    if [[ -n "$timeout_cmd" ]]; then
        $timeout_cmd "$timeout_seconds" sh -c "$cmd" 2>&1
    else
        sh -c "$cmd" 2>&1
    fi
    local exit_code=$?
    set -e
    
    if [[ -n "$timeout_cmd" && $exit_code -eq 124 ]]; then
        print_status "error" "$description превысил таймаут (${timeout_seconds}s)"
    fi
    
    return $exit_code
}
#endregion

#region Summarize command output for log
summarize_output() {
    local cmd_type="$1"
    local output="$2"
    local exit_code="$3"

    if [[ -z "$output" ]]; then
        local cmd_upper
        cmd_upper=$(echo "$cmd_type" | tr '[:lower:]' '[:upper:]')
        if [[ "$cmd_type" == "test" ]]; then
            echo "[${cmd_upper}] exit=$exit_code passed=? failed=? skipped=?"
        else
            echo "[${cmd_upper}] exit=$exit_code errors=? warnings=?"
        fi
        return
    fi

    if [[ "$cmd_type" == "build" ]]; then
        local errors warnings
        local build_summary
        build_summary=$(echo "$output" | grep -a -i -E '(error\(s\)|ошиб[а-я]+)' | tail -1) || [[ $? -eq 1 ]]
        errors=$(echo "$build_summary" | grep -a -oE '[0-9]+' | head -1) || [[ $? -eq 1 ]]
        # tail -1: warnings count is the LAST number on the warnings line
        # (e.g. "0 Error(s) 293 Warning(s)" — 293 is last, "Предупреждений: 293" — only number)
        warnings=$(echo "$output" | grep -a -i -E '(warning\(s\)|предупрежден[ияй])' | tail -1 | grep -a -oE '[0-9]+' | tail -1) || [[ $? -eq 1 ]]
        echo "[BUILD] exit=$exit_code errors=${errors:-?} warnings=${warnings:-?}"

    elif [[ "$cmd_type" == "test" ]]; then
        local passed failed skipped
        local summary_line
        summary_line=$(echo "$output" | grep -a -i -E '(test run summary|итоги тестов)' | tail -1) || [[ $? -eq 1 ]]

        if [[ -z "$summary_line" ]]; then
            # Fallback 1: per-assembly summary lines (e.g. "Пройден! : пройдено N, не пройдено N, пропущено N")
            summary_line=$(echo "$output" | grep -a -E '[Пп]ройден[!]?[ :]+не[ :]*пройден[оы]?' | tail -1) || [[ $? -eq 1 ]]
        fi

        if [[ -z "$summary_line" ]]; then
            # Fallback 2: last 3 lines of output (e.g. coverlet table)
            summary_line=$(echo "$output" | tail -3)
        fi

# Strip "не пройдено" / "failed" / "не пройден" from the line before
        # extracting passed count — avoids matching "пройдено" inside "Не пройдено"
        local clean_line
        clean_line=$(echo "$summary_line" | sed 's/[Нн]е[ :]*пройден[оы]*[ :]*[0-9]*[, ]*//' | sed 's/[Ff]ailed[ :]*[0-9]*[, ]*//')
        passed=$(echo "$clean_line" | grep -a -oE '(passed|[Пп]ройден[оы]?)[ :)]*[0-9]+' | grep -a -oE '[0-9]+' | tail -1) || [[ $? -eq 1 ]]
        failed=$(echo "$summary_line" | grep -a -oE '(failed|[Нн]е?[ :]*пройден[оы]?)[ :)]*[0-9]+' | grep -a -oE '[0-9]+' | tail -1) || [[ $? -eq 1 ]]
        skipped=$(echo "$summary_line" | grep -a -oE '(skipped|[Пп]ропущен[оы]?)[ :)]*[0-9]+' | grep -a -oE '[0-9]+' | tail -1) || [[ $? -eq 1 ]]
        echo "[TEST] exit=$exit_code passed=${passed:-?} failed=${failed:-?} skipped=${skipped:-?}"
    fi
}
#endregion

#region Функции build/test gate
check_task_loop_config() {
    local project_root="$1"
    local config_file="${project_root}/.kilo/task_loop.yaml"

    if [[ ! -f "$config_file" ]]; then
        print_config_instruction "$project_root"
        print_status "error" "Build/test gate: конфиг не найден, выполнение остановлено"
        exit 1
    fi
}

run_build_test_gate() {
    local project_root="$1"
    local config_file="${project_root}/.kilo/task_loop.yaml"
    
    # timeout опционален: если доступен — используем, если нет — выполняем без таймаута
    local timeout_cmd=""
    if command -v timeout >/dev/null 2>&1; then
        timeout_cmd="timeout"
    else
        print_status "info" "timeout не найден, команды будут выполняться без таймаута"
    fi
    
    if ! read_task_loop_config; then
        print_config_instruction "$project_root"
        print_status "info" "Build/test gate: конфиг не найден, gates пропущены"
        return 0
    fi
    
    local gate_failed=0
    
    if [[ -n "$BUILD_COMMAND" ]]; then
        print_phase "BUILD GATE" "Запуск: $BUILD_COMMAND"
        local build_output
        build_output=$(execute_gate_command "$BUILD_COMMAND" 300 "build" 2>&1)
        local build_exit_code=$?
        local build_summary
        build_summary=$(summarize_output "build" "$build_output" $build_exit_code)
        print_status "success" "$build_summary"
        
        if [[ $build_exit_code -ne 0 ]]; then
            print_status "error" "Build не прошёл (exit code: $build_exit_code)"
            echo "$build_output" | tail -50
            gate_failed=1
        fi
    else
        print_status "info" "Build gate: build_command не указан, пропущен"
    fi
    
    if [[ $gate_failed -eq 0 && -n "$TEST_COMMAND" ]]; then
        print_phase "TEST GATE" "Запуск: $TEST_COMMAND"
        local test_output
        test_output=$(execute_gate_command "$TEST_COMMAND" 300 "test" 2>&1)
        local test_exit_code=$?
        local test_summary
        test_summary=$(summarize_output "test" "$test_output" $test_exit_code)
        print_status "success" "$test_summary"
        
        if [[ $test_exit_code -ne 0 ]]; then
            print_status "error" "Тесты не прошли (exit code: $test_exit_code)"
            echo "$test_output" | tail -50
            gate_failed=1
        fi
    elif [[ $gate_failed -eq 0 ]]; then
        print_status "info" "Test gate: test_command не указан, пропущен"
    fi
    
    if [[ $gate_failed -ne 0 ]]; then
        return 1
    fi
    
    return 0
}
#endregion

#region Main
main() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Ошибка: jq требуется, но не установлен. Установите через: brew install jq" >&2
        exit 1
    fi
    
    if ! command -v $GIT_CMD >/dev/null 2>&1; then
        echo "Ошибка: git требуется, но не установлен" >&2
        exit 1
    fi
    
    if ! command -v $KILO_CMD >/dev/null 2>&1; then
        echo "Ошибка: kilo требуется, но не найден в PATH" >&2
        exit 1
    fi
    
    parse_args "$@"
    
    if [[ -z "$TASKS_PATH" ]]; then
        echo "Ошибка: --tasks-path обязателен" >&2
        exit 1
    fi
    
    PROJECT_ROOT=$($GIT_CMD rev-parse --show-toplevel 2>/dev/null || pwd)
    PROJECT_ROOT=$(realpath "$PROJECT_ROOT")
    
    check_task_loop_config "$PROJECT_ROOT"
    
    TASKS_PATH=$(validate_path "$TASKS_PATH" "tasks.md") || exit 1
    
    validate_numeric "$MAX_ITERATIONS" "--max-iterations" $MIN_ITERATIONS $MAX_ITERATIONS_LIMIT || exit 1
    
    if [[ -n "$WORKING_DIRECTORY" ]]; then
        WORKING_DIRECTORY=$(validate_path "$WORKING_DIRECTORY" "рабочая директория") || exit 1
        cd "$WORKING_DIRECTORY"
    fi
    
    
    PROMPT_FILE="${PROJECT_ROOT}/${PROMPT_FILE}"
    if [[ ! -f "$PROMPT_FILE" ]]; then
        echo "Ошибка: Файл prompt не найден: $PROMPT_FILE" >&2
        exit 1
    fi
    
    if [[ "$NO_REVIEW" != "true" ]]; then
        REVIEW_PROMPT_FILE="${PROJECT_ROOT}/${REVIEW_PROMPT_FILE}"
        if [[ ! -f "$REVIEW_PROMPT_FILE" ]]; then
            echo "⚠️  Предупреждение: Prompt для review не найден: $REVIEW_PROMPT_FILE" >&2
        fi
    fi
    
    exec 3>&1 4>&2
    trap 'exec 1>&3 2>&4; wait $TEE_PID 2>/dev/null || true' EXIT
    
    local FEATURE_NAME=$(extract_feature_name "$TASKS_PATH")
    local FEATURE_DIR=$(dirname "$TASKS_PATH")
    local TASKS_DIR="${FEATURE_DIR}/tasks"
    
    LOG_FILE="${FEATURE_DIR}/.task_loop.log"
    STATE_FILE="${FEATURE_DIR}/.task_loop_state.json"
    PENDING_TASKS_FILE="${FEATURE_DIR}/.task_loop_pending_tasks.json"
    FRONTMATTER_CACHE_FILE="${FEATURE_DIR}/.task_loop_frontmatter_cache"
    REVIEW_RESULT_FILE="${FEATURE_DIR}/.task_loop_review_result.md"
    
    if [[ ! -d "$TASKS_DIR" ]]; then
        echo "⚠️  Предупреждение: Директория tasks не найдена: $TASKS_DIR (используется старый формат)" >&2
        TASKS_DIR=""
    fi
    
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    touch "$STATE_FILE" && chmod 600 "$STATE_FILE"
    
    exec > >(tee -a "$LOG_FILE") 2>&1
    TEE_PID=$!
    
    echo "🚀 Запуск Task Loop..."
    echo "Задачи: $TASKS_PATH"
    echo "Фича: $FEATURE_NAME"
    echo "Максимум итераций: $MAX_ITERATIONS"
    echo "Review включён: $(if [[ "$NO_REVIEW" == "true" ]]; then echo "НЕТ"; else echo "ДА"; fi)"
    echo "Режим: ОДНА ЗАДАЧА ЗА ИТЕРАЦИЮ"
    echo ""
    
    local iteration=0
    local tasks_completed=0
    local consecutive_failures=0
    local impl_failures=0
    local infra_failures=0
    local review_retries=0
    local total_attempts=0
    local failed_tasks="[]"
    local task_rejection_counts="{}"
    local max_total_attempts=$((MAX_ITERATIONS * MAX_TOTAL_ATTEMPTS_MULTIPLIER))
    local coordinator_session_id=""
    
    load_state

    rm -f "$REVIEW_RESULT_FILE"
    
    while [[ $total_attempts -lt $max_total_attempts ]]; do
        ((total_attempts++))
        print_header "$iteration" "$MAX_ITERATIONS"
        
        local next_task=""
        
        # Check if previous iteration was REJECTED - continue with same task
        if [[ -f "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
            local prev_state=$(jq -r '.state // empty' "$STATE_FILE" 2>/dev/null)
            local prev_task=$(jq -r '.current_task // empty' "$STATE_FILE" 2>/dev/null)
            
            if [[ "$prev_state" == "REJECTED" && -n "$prev_task" ]]; then
                # Verify task file still exists before continuing
                local task_file_to_check=""
                if [[ -d "$TASKS_DIR" ]]; then
                    task_file_to_check="${TASKS_DIR}/${prev_task}.md"
                else
                    task_file_to_check="$TASKS_PATH"
                fi
                
                if [[ -f "$task_file_to_check" ]]; then
                    print_status "info" "Продолжение работы над отклонённой задачей: $prev_task"
                    next_task="$prev_task"
                else
                    print_status "warning" "Task file для REJECTED задачи не найден: $task_file_to_check"
                    print_status "info" "Fallback к нормальному выбору задачи"
                fi
            fi
        fi
        
        # Normal task selection if not REJECTED continuation
        if [[ -z "$next_task" ]]; then
            if [[ -d "$TASKS_DIR" ]]; then
                next_task=$(get_next_executable_task "$TASKS_PATH" "$TASKS_DIR")
                
                if [[ -z "$next_task" ]]; then
                    local incomplete=$(get_incomplete_task_count "$TASKS_PATH")
                    if [[ $incomplete -gt 0 ]]; then
                        print_status "error" "Все оставшиеся задачи заблокированы невыполненными dependencies"
                        print_status "info" "Невыполненных задач: $incomplete"
                        print_summary "$tasks_completed" "ALL_BLOCKED" "$total_attempts"
                        exit 1
                    fi
                fi
            else
                next_task=$(get_first_incomplete_task "$TASKS_PATH")
            fi
        fi
        
        if [[ -z "$next_task" ]]; then
            echo ""
            save_state "COMPLETE" "$iteration" ""
            print_status "success" "🎉 Все задачи выполнены!"
            print_summary "$tasks_completed" "COMPLETE" "$total_attempts"
            exit 0
        fi
        
        rm -f "$PENDING_TASKS_FILE"
        
        # =====================================================
        # ФАЗА 1: Реализация (ОДНА ЗАДАЧА)
        # =====================================================
        
        print_phase "ФАЗА 1: Реализация" "Работа над задачей $next_task"
        save_state "IMPLEMENTING" "$iteration" "$next_task"
        
        local TASK_FILE_PATH=""
        if [[ -d "$TASKS_DIR" ]]; then
            TASK_FILE_PATH="$TASKS_DIR/${next_task}.md"
        else
            TASK_FILE_PATH="$TASKS_PATH"
        fi
        
        local safe_task_path=$(printf '%q' "$TASK_FILE_PATH")
        local safe_pending_path=$(printf '%q' "$PENDING_TASKS_FILE")
        local safe_feature_dir=$(printf '%q' "$FEATURE_DIR")
        local safe_review_result=$(printf '%s' "$REVIEW_RESULT_FILE" | sed 's/[&/\]/\\&/g')

        local PROMPT=$(sed "s|\$TASKS_PATH|$safe_task_path|g" "$PROMPT_FILE")
        PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$safe_pending_path|g" <<< "$PROMPT")
        PROMPT=$(sed "s|\$FEATURE_DIR|$safe_feature_dir|g" <<< "$PROMPT")
        PROMPT=$(sed "s|\$REVIEW_RESULT_FILE|$safe_review_result|g" <<< "$PROMPT")
        PROMPT=$(printf '%s' "$PROMPT")
        
        local exit_code
        set +e
        run_kilo_with_sentinel "$next_task" "$PROMPT" "$PENDING_TASKS_FILE" "$PENDING_GRACE_SECONDS" ""
        exit_code=$?
        set -e
        
        local escalation_file="${FEATURE_DIR}/.escalation_handoff.md"
        local escalation_file_alt="${PROJECT_ROOT}/.escalation_handoff.md"

        # Standard location: feature directory
        # Fallback: project root (for backward compatibility)
        if [[ -f "$escalation_file_alt" ]] && [[ ! -f "$escalation_file" ]]; then
            print_status "warning" "Escalation file in project root. Standard location: ${FEATURE_DIR}/.escalation_handoff.md"
            escalation_file="$escalation_file_alt"
        fi

        if [[ -f "$escalation_file" ]]; then
            save_state "ESCALATION" "$iteration" "$next_task"
            
            echo ""
            echo "⚠️  ESCALATION DETECTED"
            echo ""
            echo "Task $next_task requires clarification."
            echo ""
            echo "Handoff document: $escalation_file"
            echo ""
            echo "NEXT STEPS:"
            echo "1. Review $escalation_file"
            echo "2. Run: kilo run \"Analyze escalation and create fix-tasks for $FEATURE_DIR\""
            echo "3. Review .proposed_fix_tasks.md and confirm"
            echo "4. Re-run: ./task_loop.sh --tasks-path $TASKS_PATH"
            echo ""
            
            print_summary "$tasks_completed" "ESCALATION" "$total_attempts"
            exit 2
        fi
        
        if [[ $exit_code -ne 0 ]]; then
            save_state "FAILED" "$iteration" "$next_task"
            ((iteration++))
            
            print_status "error" "Итерация $iteration: реализация не удалась для задачи $next_task"
            
            local failure_result
            failure_result=$(handle_failure "реализации" "$impl_failures" "$MAX_CONSECUTIVE_FAILURES" "CIRCUIT_BREAKER")
            
            if [[ "$failure_result" == "CIRCUIT_BREAKER" ]]; then
                exit 1
            fi
            
            impl_failures="$failure_result"
            consecutive_failures="$impl_failures"
            
            if [[ $iteration -ge $MAX_ITERATIONS ]]; then
                print_status "error" "Достигнут максимум итераций"
                print_summary "$tasks_completed" "MAX_ITERATIONS_REACHED" "$total_attempts"
                exit 1
            fi
            
            continue
        fi
        
        impl_failures=0
        
        # =====================================================
        # TEST GATE: Автоматический запуск тестов
        # =====================================================
        
        if ! run_build_test_gate "$PROJECT_ROOT"; then
            print_status "error" "Test gate не пройден для задачи $next_task"
            save_state "TEST_FAILED" "$iteration" "$next_task"
            ((iteration++))
            
            local failure_result
            failure_result=$(handle_failure "тестов" "$impl_failures" "$MAX_CONSECUTIVE_FAILURES" "TEST_FAILURES")
            
            if [[ "$failure_result" == "CIRCUIT_BREAKER" ]]; then
                exit 1
            fi
            
            impl_failures="$failure_result"
            consecutive_failures="$impl_failures"
            continue
        fi
        
        # =====================================================
        # ФАЗА 2: Review Gate
        # =====================================================
        
        if [[ ! -f "$PENDING_TASKS_FILE" ]]; then
            print_status "info" "Файл pending task не создан — задача может быть уже выполнена или агенту нечего было делать"
            continue
        fi
        
        if ! jq -e . "$PENDING_TASKS_FILE" >/dev/null 2>&1; then
            print_status "error" "Некорректный JSON в файле pending tasks"
            continue
        fi
        
        local pending_task_id=$(jq -r '.task_id' "$PENDING_TASKS_FILE" 2>/dev/null || echo "")
        
        if [[ -z "$pending_task_id" ]]; then
            print_status "failure" "Некорректный файл pending tasks"
            continue
        fi
        
        print_status "info" "Задача $pending_task_id готова к review"
        save_state "REVIEWING" "$iteration" "$pending_task_id"
        
        set +e
        run_review_gate "$iteration" "$pending_task_id" "$PENDING_TASKS_FILE" "$TASK_FILE_PATH"
        local review_result=$?
        set -e
        
        if [[ $review_result -eq 2 ]]; then
            print_status "error" "Ошибка Kilo или некорректный вывод review"
            ((iteration++))
            
            local failure_result
            failure_result=$(handle_failure "Kilo ошибки" "$infra_failures" "$MAX_CONSECUTIVE_FAILURES" "KILO_ERRORS")
            
            if [[ "$failure_result" == "CIRCUIT_BREAKER" ]]; then
                print_status "error" "Инфраструктурные ошибки — возможно kilo недоступен"
                create_escalation_for_review_failure "$pending_task_id"
                exit 1
            fi
            
            infra_failures="$failure_result"
            consecutive_failures="$infra_failures"
            continue
            
        elif [[ $review_result -eq 1 ]]; then
            ((iteration++))
            
            local current_rejections
            current_rejections=$(echo "$task_rejection_counts" | jq -r --arg t "$pending_task_id" '.[$t] // 0' 2>/dev/null | head -1 | tr -dc '0-9')
            [[ -z "$current_rejections" ]] && current_rejections=0
            ((current_rejections++))
            task_rejection_counts=$(echo "$task_rejection_counts" | jq --arg t "$pending_task_id" --argjson c "$current_rejections" '.[$t] = $c' 2>/dev/null || echo "{}")
            
            print_status "info" "Задача $pending_task_id отклонена $current_rejections/$MAX_TASK_REJECTIONS раз"
            
            save_state "REJECTED" "$iteration" "$pending_task_id"
            
            if [[ $current_rejections -ge $MAX_TASK_REJECTIONS ]]; then
                print_status "error" "Задача $pending_task_id отклонена $MAX_TASK_REJECTIONS раз — escalation"
                create_escalation_for_review_failure "$pending_task_id"
                print_summary "$tasks_completed" "TASK_REJECTION_LIMIT" "$total_attempts"
                exit 1
            fi
            
            if [[ $iteration -ge $MAX_ITERATIONS ]]; then
                print_status "error" "Достигнут максимум итераций"
                print_summary "$tasks_completed" "MAX_ITERATIONS_REACHED" "$total_attempts"
                exit 1
            fi
            
            continue
        fi
        
        # =====================================================
        # ФАЗА 3: Пометить выполненной и закоммитить
        # =====================================================
        
        # Cleanup coordinator session after APPROVED
        if [[ -n "$coordinator_session_id" ]]; then
            local delete_attempt=1
            local delete_max=3
            while [[ $delete_attempt -le $delete_max ]]; do
                if timeout 5 $KILO_CMD session delete "$coordinator_session_id" 2>/dev/null; then
                    print_status "info" "Coordinator session deleted: $coordinator_session_id"
                    break
                fi
                if [[ $delete_attempt -lt $delete_max ]]; then
                    print_status "warning" "Failed to delete session (attempt $delete_attempt/$delete_max)"
                    $SLEEP_CMD 1
                fi
                ((delete_attempt++))
            done
            coordinator_session_id=""
        fi
        
        task_rejection_counts=$(echo "$task_rejection_counts" | jq --arg t "$pending_task_id" 'del(.[$t])' 2>/dev/null || echo "{}")
        save_state "COMMITTING" "$iteration" "$pending_task_id"
        
        mark_task_completed "$TASKS_PATH" "$pending_task_id"
        
        if [[ "$NO_COMMIT" != "true" ]]; then
            do_commit "$FEATURE_NAME" "$pending_task_id" "$iteration"
        else
            print_status "info" "Коммит пропущен (--no-commit)"
        fi
        ((tasks_completed++))
        
        rm -f "$PENDING_TASKS_FILE"
        
        if [[ -f "$REVIEW_RESULT_FILE" ]]; then
            local review_decision
            review_decision=$(parse_frontmatter_decision "$REVIEW_RESULT_FILE")
            if [[ "$review_decision" == "APPROVED" ]]; then
                rm -f "$REVIEW_RESULT_FILE"
            fi
        fi
        
        rm -f "$FRONTMATTER_CACHE_FILE"
        
        save_state "IDLE" "$iteration" ""
        
        if [[ "$VERBOSE" == "true" ]]; then
            local remaining=$(get_incomplete_task_count "$TASKS_PATH")
            print_status "info" "Осталось задач: $remaining"
        fi
        
        $SLEEP_CMD 1
    done
    
    print_summary "$tasks_completed" "MAX_ATTEMPTS_REACHED" "$total_attempts"
}

#endregion

main "$@"
