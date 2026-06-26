#!/usr/bin/env bash
#
# ralph_loop.sh - Ralph loop orchestrator for Kilo CLI with Review Gate
#
# Использование:
#   ./ralph_loop.sh --tasks-path PATH [--max-iterations N] [--verbose] [--no-review] [--no-commit] [--working-directory DIR]
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
#   - Tolерантность к неудачам review: 2 неудачи review до остановки
#   - Exponential backoff при неудачах (макс 60с)
#   - Информативный вывод с временными метками
#

set -euo pipefail

#region Константы
readonly MAX_CONSECUTIVE_FAILURES=3
readonly MAX_REVIEW_FAILURES=2
readonly MAX_BACKOFF_SECONDS=60
readonly MAX_TOTAL_ATTEMPTS_MULTIPLIER=10
readonly DEFAULT_MAX_ITERATIONS=50
readonly MIN_ITERATIONS=1
readonly MAX_ITERATIONS_LIMIT=1000
#endregion

#region Конфигурация
TASKS_PATH=""
MAX_ITERATIONS=$DEFAULT_MAX_ITERATIONS
VERBOSE=false
NO_REVIEW=false
NO_COMMIT=false
WORKING_DIRECTORY=""
PROJECT_ROOT=""
PROMPT_FILE=".kilo/prompts/ralph-iterate.md"
REVIEW_PROMPT_FILE=".kilo/prompts/ralph-review.md"
LOCK_FILE="/tmp/ralph_loop_${USER}.lock"
LOG_FILE=""
STATE_FILE=""
PENDING_TASKS_FILE=""
STATUS_CACHE_FILE=""
FRONTMATTER_CACHE_FILE=""
REVIEW_RESULT_FILE=""

# DI для тестирования
KILO_CMD="${KILO_CMD:-kilo}"
GIT_CMD="${GIT_CMD:-git}"
SLEEP_CMD="${SLEEP_CMD:-sleep}"
#endregion

#region Функции для работы с dependencies
build_task_status_cache() {
    local tasks_file="$1"
    local cache_file="$2"
    
    > "$cache_file"
    
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^\s*-\s*\[([x ])\]\s+T[0-9]+'; then
            local task_id=$(echo "$line" | grep -oE 'T[0-9]+' | head -1)
            local bracket=$(echo "$line" | grep -oE '\[([x ])\]')
            local task_status=$(echo "$bracket" | sed 's/\[\(.\)\]/\1/')
            echo "${task_id}=${task_status}" >> "$cache_file"
        fi
    done < "$tasks_file"
}

get_task_status() {
    local task_id="$1"
    local cache_file="$2"
    
    grep "^${task_id}=" "$cache_file" 2>/dev/null | cut -d'=' -f2 || echo ""
}

parse_frontmatter_cached() {
    local task_file="$1"
    local cache_file="$2"
    
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return
    fi
    
    local deps=""
    if [[ -f "$task_file" ]]; then
        deps=$(grep '^dependencies:' "$task_file" 2>/dev/null | sed -n 's/^dependencies: \[\(.*\)\]/\1/p' | tr -d ' ' | tr ',' '\n' | grep -E '^T[0-9]+$' || echo "")
    fi
    
    echo "$deps" > "$cache_file"
    echo "$deps"
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
    local status_cache="$2"
    local frontmatter_cache="$3"
    
    local deps
    deps=$(parse_frontmatter_cached "$task_file" "$frontmatter_cache")
    
    [[ -z "$deps" ]] && return 0
    
    for dep in $deps; do
        if [[ "$(get_task_status "$dep" "$status_cache")" != "x" ]]; then
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
    
    return $errors
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

print_phase() {
    local phase=$1
    local message=$2
    local timestamp=$(date +'%H:%M:%S')
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "[$timestamp] $phase: $message"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

print_status() {
    local status=$1
    local message=$2
    local timestamp=$(date +'%H:%M:%S')
    local icon=""
    
    case "$status" in
        success) icon="✅" ;;
        failure) icon="⚠️ " ;;
        error)   icon="❌" ;;
        info)    icon="ℹ️ " ;;
    esac
    
    echo "[$timestamp] $icon $message"
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
    local status_cache="$3"
    
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^\s*-\s*\[ \]\s+[A-Z0-9-]+'; then
            local task_id=$(echo "$line" | grep -oE '[A-Z]+-[0-9]+|T[0-9]+' | head -1)
            
            local task_file="$tasks_dir/${task_id}.md"
            local frontmatter_cache="/tmp/.frontmatter_${task_id}_$$"
            
            if [[ ! -f "$task_file" ]]; then
                print_status "failure" "Файл задачи не найден: $task_file"
                continue
            fi
            
            if check_dependencies "$task_file" "$status_cache" "$frontmatter_cache"; then
                rm -f "$frontmatter_cache"
                echo "$task_id"
                return 0
            fi
            
            rm -f "$frontmatter_cache"
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
    echo "  Ralph Loop — Сводка"
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
    
    cat > "$STATE_FILE" << STATE_JSON
{
  "state": "$state",
  "iteration": $iteration,
  "current_task": "$current_task",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pid": $$,
  "review_retries": ${review_retries:-0},
  "failed_tasks": $(echo "${failed_tasks:-[]}" | jq -c . 2>/dev/null || echo "[]"),
  "consecutive_failures": ${consecutive_failures:-0}
}
STATE_JSON
}
#endregion

#region Функции Review Gate
run_review_gate() {
    local iteration=$1
    local task_id=$2
    local pending_file=$3
    
    if [[ "$NO_REVIEW" == "true" ]]; then
        print_status "info" "Review gate отключён (--no-review)"
        return 0
    fi
    
    print_phase "ФАЗА 2: Review Gate" "Проверка задачи $task_id"
    
    rm -f "$REVIEW_RESULT_FILE"
    
    local safe_tasks_path=$(printf '%s' "$TASKS_PATH" | sed 's/[&/\]/\\&/g')
    local safe_pending_file=$(printf '%s' "$pending_file" | sed 's/[&/\]/\\&/g')
    local safe_review_result=$(printf '%s' "$REVIEW_RESULT_FILE" | sed 's/[&/\]/\\&/g')
    
    local PROMPT=$(sed "s|\$TASKS_PATH|$safe_tasks_path|g" "$REVIEW_PROMPT_FILE")
    PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$safe_pending_file|g" <<< "$PROMPT")
    PROMPT=$(sed "s|\$REVIEW_RESULT_FILE|$safe_review_result|g" <<< "$PROMPT")
    
    set +e
    $KILO_CMD run --auto "$PROMPT"
    local exit_code=$?
    set -e
    
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

migrate_old_files() {
    local migrated=0
    
    local old_files=(
        ".ralph_state.json"
        ".ralph_loop.log"
        ".ralph_pending_tasks.json"
        ".ralph_rejection_context.md"
        ".ralph_review_results.md"
        ".ralph_status_cache"
        ".ralph_frontmatter_cache"
    )
    
    for old_file in "${old_files[@]}"; do
        local old_path="${PROJECT_ROOT}/${old_file}"
        local new_path="${FEATURE_DIR}/${old_file}"
        
        if [[ -f "$old_path" ]] && [[ ! -f "$new_path" ]]; then
            print_status "info" "Migrating old file: $old_file → $FEATURE_DIR/"
            mv "$old_path" "$new_path" 2>/dev/null && ((migrated++))
        fi
    done
    
    rm -f "${PROJECT_ROOT}/.ralph_rejection_context.md" 2>/dev/null
    rm -f "${PROJECT_ROOT}/.ralph_review_results.md" 2>/dev/null
    
    if [[ $migrated -gt 0 ]]; then
        print_status "success" "Migrated $migrated file(s) to new format"
    fi
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
        REVIEW_PROMPT_FILE="${PROJECT_ROOT}/.kilo/prompts/ralph-review.md"
        if [[ ! -f "$REVIEW_PROMPT_FILE" ]]; then
            echo "⚠️  Предупреждение: Prompt для review не найден: $REVIEW_PROMPT_FILE" >&2
        fi
    fi
    
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "Ошибка: Другой экземпляр уже запущен (PID: $lock_pid)" >&2
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"

    # Save original file descriptors for proper tee cleanup
    exec 3>&1 4>&2
    trap 'exec 1>&3 2>&4; wait $TEE_PID 2>/dev/null; rm -f "$LOCK_FILE"' EXIT
    
    local FEATURE_NAME=$(extract_feature_name "$TASKS_PATH")
    local FEATURE_DIR=$(dirname "$TASKS_PATH")
    local TASKS_DIR="${FEATURE_DIR}/tasks"
    
    LOG_FILE="${FEATURE_DIR}/.ralph_loop.log"
    STATE_FILE="${FEATURE_DIR}/.ralph_state.json"
    PENDING_TASKS_FILE="${FEATURE_DIR}/.ralph_pending_tasks.json"
    STATUS_CACHE_FILE="${FEATURE_DIR}/.ralph_status_cache"
    FRONTMATTER_CACHE_FILE="${FEATURE_DIR}/.ralph_frontmatter_cache"
    REVIEW_RESULT_FILE="${FEATURE_DIR}/.ralph_review_result.md"
    
    if [[ ! -d "$TASKS_DIR" ]]; then
        echo "⚠️  Предупреждение: Директория tasks не найдена: $TASKS_DIR (используется старый формат)" >&2
        TASKS_DIR=""
    fi
    
    migrate_old_files
    
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    touch "$STATE_FILE" && chmod 600 "$STATE_FILE"
    
    exec > >(tee -a "$LOG_FILE") 2>&1
    TEE_PID=$!
    
    echo "🚀 Запуск Ralph Loop..."
    echo "Задачи: $TASKS_PATH"
    echo "Фича: $FEATURE_NAME"
    echo "Максимум итераций: $MAX_ITERATIONS"
    echo "Review включён: $(if [[ "$NO_REVIEW" == "true" ]]; then echo "НЕТ"; else echo "ДА"; fi)"
    echo "Режим: ОДНА ЗАДАЧА ЗА ИТЕРАЦИЮ"
    echo ""
    
    local iteration=0
    local tasks_completed=0
    local consecutive_failures=0
    local review_retries=0
    local review_failures=0
    local total_attempts=0
    local failed_tasks="[]"
    local max_total_attempts=$((MAX_ITERATIONS * MAX_TOTAL_ATTEMPTS_MULTIPLIER))
    
    build_task_status_cache "$TASKS_PATH" "$STATUS_CACHE_FILE"
    
    while [[ $total_attempts -lt $max_total_attempts ]]; do
        ((total_attempts++))
        print_header "$iteration" "$MAX_ITERATIONS"
        
        local next_task=""
        
        if [[ -d "$TASKS_DIR" ]]; then
            next_task=$(get_next_executable_task "$TASKS_PATH" "$TASKS_DIR" "$STATUS_CACHE_FILE")
            
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

        local PROMPT=$(sed "s|\$TASKS_PATH|$safe_task_path|g" "$PROMPT_FILE")
        PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$safe_pending_path|g" <<< "$PROMPT")
        PROMPT=$(sed "s|\$FEATURE_DIR|$safe_feature_dir|g" <<< "$PROMPT")
        PROMPT=$(printf '%s' "$PROMPT")
        
        set +e
        $KILO_CMD run --auto "$PROMPT"
        local exit_code=$?
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
            echo "4. Re-run: ./ralph_loop.sh --tasks-path $TASKS_PATH"
            echo ""
            
            print_summary "$tasks_completed" "ESCALATION" "$total_attempts"
            exit 2
        fi
        
        if [[ $exit_code -ne 0 ]]; then
            save_state "FAILED" "$iteration" "$next_task"
            ((iteration++))
            
            print_status "error" "Итерация $iteration: реализация не удалась для задачи $next_task"
            
            local failure_result
            failure_result=$(handle_failure "реализации" "$consecutive_failures" "$MAX_CONSECUTIVE_FAILURES" "CIRCUIT_BREAKER")
            
            if [[ "$failure_result" == "CIRCUIT_BREAKER" ]]; then
                exit 1
            fi
            
            consecutive_failures="$failure_result"
            
            if [[ $iteration -ge $MAX_ITERATIONS ]]; then
                print_status "error" "Достигнут максимум итераций"
                print_summary "$tasks_completed" "MAX_ITERATIONS_REACHED" "$total_attempts"
                exit 1
            fi
            
            continue
        fi
        
        consecutive_failures=0
        
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
        run_review_gate "$iteration" "$pending_task_id" "$PENDING_TASKS_FILE"
        local review_result=$?
        set -e
        
        if [[ $review_result -eq 2 ]]; then
            print_status "error" "Ошибка Kilo или некорректный вывод review"
            ((iteration++))
            
            local failure_result
            failure_result=$(handle_failure "Kilo ошибки" "$consecutive_failures" "$MAX_CONSECUTIVE_FAILURES" "KILO_ERRORS")
            
            if [[ "$failure_result" == "CIRCUIT_BREAKER" ]]; then
                exit 1
            fi
            
            consecutive_failures="$failure_result"
            continue
            
        elif [[ $review_result -eq 1 ]]; then
            ((review_failures++))
            ((iteration++))
            print_status "failure" "Неудача review $review_failures/$MAX_REVIEW_FAILURES (итерация $iteration)"
            
            if [[ $review_failures -ge $MAX_REVIEW_FAILURES ]]; then
                print_status "error" "Слишком много неудач review"
                print_summary "$tasks_completed" "REVIEW_FAILURES" "$total_attempts"
                exit 1
            fi
            
            if [[ $iteration -ge $MAX_ITERATIONS ]]; then
                print_status "error" "Достигнут максимум итераций"
                print_summary "$tasks_completed" "MAX_ITERATIONS_REACHED" "$total_attempts"
                exit 1
            fi
            
            save_state "REJECTED" "$iteration" "$pending_task_id"
            continue
        fi
        
        # =====================================================
        # ФАЗА 3: Пометить выполненной и закоммитить
        # =====================================================
        
        review_failures=0
        save_state "COMMITTING" "$iteration" "$pending_task_id"
        
        mark_task_completed "$TASKS_PATH" "$pending_task_id"
        
        build_task_status_cache "$TASKS_PATH" "$STATUS_CACHE_FILE"
        
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
