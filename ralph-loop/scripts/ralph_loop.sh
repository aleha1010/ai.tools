#!/usr/bin/env bash
#
# ralph_loop.sh - Ralph loop orchestrator for Kilo CLI with Review Gate
#
# Использование:
#   ./ralph_loop.sh --tasks-path PATH [--max-iterations N] [--verbose] [--no-review] [--working-directory DIR]
#
# Конфигурация:
#   --tasks-path PATH        Путь к tasks.md (обязательно)
#   --max-iterations N       Максимум итераций (по умолчанию: 50, диапазон: 1-1000)
#   --verbose                Подробный вывод
#   --no-review              Отключить review gate (для hotfix)
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
WORKING_DIRECTORY=""
PROJECT_ROOT=""
PROMPT_FILE=".kilo/prompts/ralph-iterate.md"
REVIEW_PROMPT_FILE=".kilo/prompts/ralph-review.md"
LOCK_FILE="/tmp/ralph_loop_${USER}.lock"
LOG_FILE=""
STATE_FILE=""
PENDING_TASKS_FILE=""

# DI для тестирования
KILO_CMD="${KILO_CMD:-kilo}"
GIT_CMD="${GIT_CMD:-git}"
SLEEP_CMD="${SLEEP_CMD:-sleep}"
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
            --working-directory)
                if [[ -z "${2:-}" ]]; then
                    echo "Ошибка: --working-directory требует значение" >&2
                    return 1
                fi
                WORKING_DIRECTORY="$2"
                shift 2
                ;;
            --help|-h)
                echo "Использование: $0 --tasks-path PATH [--max-iterations N] [--verbose] [--no-review] [--working-directory DIR]"
                echo ""
                echo "Параметры:"
                echo "  --tasks-path PATH        Путь к tasks.md (обязательно)"
                echo "  --max-iterations N       Максимум итераций (по умолчанию: 50)"
                echo "  --verbose                Подробный вывод"
                echo "  --no-review              Отключить review gate"
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
    grep -m 1 "^\s*-\s*\[ \]" "$tasks_file" 2>/dev/null | grep -oE 'T[0-9]+' || echo ""
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
    
    cat > "$STATE_FILE" << EOF
{
  "state": "$state",
  "iteration": $iteration,
  "current_task": "$current_task",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pid": $$
}
EOF
}
#endregion

#region Функции Review Gate
run_review_gate() {
    local iteration=$1
    local task_id=$2
    local pending_file=$3
    local review_prompt_file="$REVIEW_PROMPT_FILE"
    
    if [[ "$NO_REVIEW" == "true" ]]; then
        print_status "info" "Review gate отключён (--no-review)"
        return 0
    fi
    
    if [[ ! -f "$review_prompt_file" ]]; then
        print_status "failure" "Prompt для review не найден: $review_prompt_file"
        print_status "info" "Пропуск review gate..."
        return 1
    fi
    
    print_phase "ФАЗА 2: Review Gate" "Проверка задачи $task_id"
    
    local PROMPT=$(sed "s|\$TASKS_PATH|$TASKS_PATH|g" "$review_prompt_file")
    PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$pending_file|g" <<< "$PROMPT")
    
    set +e
    local review_output
    review_output=$($KILO_CMD run --auto "$PROMPT" 2>&1)
    local review_exit_code=$?
    set -e
    
    if echo "$review_output" | grep -q "Session not found\|Error:"; then
        print_status "error" "Ошибка Kilo — проблема с сессией"
        echo "$review_output" | grep -E "Error:|Session not found" | head -3
        return 2
    fi
    
    local decision=""
    decision=$(echo "$review_output" | grep -o "### Decision: APPROVED\|### Decision: REJECTED" | head -1 | sed 's/### Decision: //')
    
    if [[ "$decision" == "APPROVED" ]]; then
        print_status "success" "Review ПРОЙДЕН — Задача $task_id одобрена"
        echo ""
        return 0
    elif [[ "$decision" == "REJECTED" ]]; then
        print_status "error" "Review ОТКЛОНЁН — Задаче $task_id требуются исправления"
        echo ""
        
        local review_results_block=""
        review_results_block=$(echo "$review_output" | sed -n '/^REVIEW RESULTS:/,$p')
        echo "$review_results_block" > "${PROJECT_ROOT}/.ralph_review_results.md"
        print_status "info" "Результаты review сохранены в .ralph_review_results.md"
        
        local rejection_context_file="${PROJECT_ROOT}/.ralph_rejection_context.md"
        local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
        
        cat > "$rejection_context_file" << REJECTION_CTX
# Контекст отклонения Review

**Время**: $timestamp
**ID задачи**: $task_id

## ⚠️ ВАЖНО: ИСПРАВЬ ЭТУ ЖЕ ЗАДАЧУ

Твоя задача $task_id была отклонена на review.
Ты ДОЛЖЕН исправить замечания и снова отправить ЕЁ ЖЕ на review.
НЕ переходи к следующей задаче пока эта не пройдёт review.

---

## Результаты Review

$review_results_block

---

## Требуемые действия

1. Прочитай замечания reviewers выше
2. Исправь проблемы в коде
3. Создай файл $PENDING_TASKS_FILE с task_id: "$task_id"
4. НЕ начинай новые задачи пока эта не одобрена
REJECTION_CTX
        
        print_status "info" "Контекст отклонения сохранён в: $rejection_context_file"
        return 1
    else
        if [[ $review_exit_code -ne 0 ]]; then
            print_status "failure" "Review завершился с кодом $review_exit_code"
            return 2
        fi
        
        print_status "failure" "Не найден валидный REVIEW RESULTS в выводе"
        return 2
    fi
}

do_commit() {
    local feature_name="$1"
    local task_id="$2"
    local iteration="$3"
    
    echo ""
    print_phase "ФАЗА 3: Коммит" "Создание git коммита для $task_id"
    
    local commit_message="feat(${feature_name}): ${task_id}"
    
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
    
    LOG_FILE="${PROJECT_ROOT}/.ralph_loop.log"
    STATE_FILE="${PROJECT_ROOT}/.ralph_state.json"
    PENDING_TASKS_FILE="${PROJECT_ROOT}/.ralph_pending_tasks.json"
    
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    touch "$STATE_FILE" && chmod 600 "$STATE_FILE"
    
    exec > >(tee -a "$LOG_FILE") 2>&1
    
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
    trap 'rm -f "$LOCK_FILE"' EXIT
    
    local FEATURE_NAME=$(extract_feature_name "$TASKS_PATH")
    
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
    local review_failures=0
    local total_attempts=0
    local max_total_attempts=$((MAX_ITERATIONS * MAX_TOTAL_ATTEMPTS_MULTIPLIER))
    
    while [[ $total_attempts -lt $max_total_attempts ]]; do
        ((total_attempts++))
        print_header "$iteration" "$MAX_ITERATIONS"
        
        local next_task=$(get_first_incomplete_task "$TASKS_PATH")
        
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
        
        local PROMPT=$(sed "s|\$TASKS_PATH|$TASKS_PATH|g" "$PROMPT_FILE")
        PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$PENDING_TASKS_FILE|g" <<< "$PROMPT")
        PROMPT=$(printf '%s' "$PROMPT")
        
        set +e
        $KILO_CMD run --auto "$PROMPT"
        local exit_code=$?
        set -e
        
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
        do_commit "$FEATURE_NAME" "$pending_task_id" "$iteration"
        ((tasks_completed++))
        
        rm -f "$PENDING_TASKS_FILE"
        rm -f "${PROJECT_ROOT}/.ralph_rejection_context.md"
        
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
