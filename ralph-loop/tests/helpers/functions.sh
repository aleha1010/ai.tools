#!/usr/bin/env bash
#
# Helper functions for testing Ralph Loop
# Этот файл source'ится из тестов и предоставляет доступ к функциям скрипта
#

# Устанавливаем PROJECT_ROOT если не установлен
if [[ -z "${PROJECT_ROOT:-}" ]]; then
    export PROJECT_ROOT="$(pwd)"
fi

# Константы (должны совпадать с основным скриптом)
readonly MAX_CONSECUTIVE_FAILURES=3
readonly MAX_REVIEW_FAILURES=2
readonly MAX_BACKOFF_SECONDS=60

# DI для тестирования
KILO_CMD="${KILO_CMD:-kilo}"
GIT_CMD="${GIT_CMD:-git}"
SLEEP_CMD="${SLEEP_CMD:-sleep}"

source_functions() {
    # validate_path - модифицированная для тестов (принимает PROJECT_ROOT как аргумент)
    validate_path() {
        local path="$1"
        local description="$2"
        local project_root="${3:-$PROJECT_ROOT}"
        
        if [[ ! -e "$path" ]]; then
            echo "Ошибка: $description не найден: $path" >&2
            return 1
        fi
        
        path=$(realpath "$path")
        local project_root_real
        project_root_real=$(realpath "$project_root")
        
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
    
    calculate_backoff() {
        local failure_count=$1
        local backoff=$((2 ** failure_count))
        [[ $backoff -gt $MAX_BACKOFF_SECONDS ]] && backoff=$MAX_BACKOFF_SECONDS
        echo "$backoff"
    }
    
    run_review_gate() {
        local iteration=$1
        local task_id=$2
        local pending_file=$3
        local review_prompt_file="${REVIEW_PROMPT_FILE:-.kilo/prompts/ralph-review.md}"
        
        if [[ "${NO_REVIEW:-false}" == "true" ]]; then
            print_status "info" "Review gate отключён (--no-review)"
            return 0
        fi
        
        if [[ ! -f "$review_prompt_file" ]]; then
            print_status "failure" "Prompt для review не найден: $review_prompt_file"
            return 1
        fi
        
        print_phase "ФАЗА 2: Review Gate" "Проверка задачи $task_id"
        
        local PROMPT=$(sed "s|\$TASKS_PATH|${TASKS_PATH:-tasks.md}|g" "$review_prompt_file")
        PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$pending_file|g" <<< "$PROMPT")
        
        set +e
        local review_output
        review_output=$($KILO_CMD run --auto "$PROMPT" 2>&1)
        local review_exit_code=$?
        set -e
        
        if echo "$review_output" | grep -q "Session not found\|Error:"; then
            print_status "error" "Ошибка Kilo — проблема с сессией"
            return 2
        fi
        
        local decision=""
        decision=$(echo "$review_output" | grep -o "### Decision: APPROVED\|### Decision: REJECTED" | head -1 | sed 's/### Decision: //')
        
        if [[ "$decision" == "APPROVED" ]]; then
            print_status "success" "Review ПРОЙДЕН — Задача $task_id одобрена"
            return 0
        elif [[ "$decision" == "REJECTED" ]]; then
            print_status "error" "Review ОТКЛОНЁН — Задаче $task_id требуются исправления"
            
            local review_results_block=""
            review_results_block=$(echo "$review_output" | sed -n '/^REVIEW RESULTS:/,$p')
            echo "$review_results_block" > "${PROJECT_ROOT}/.ralph_review_results.md"
            
            local rejection_context_file="${PROJECT_ROOT}/.ralph_rejection_context.md"
            local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
            
            cat > "$rejection_context_file" << REJECTION_CTX
# Контекст отклонения Review

**Время**: $timestamp
**ID задачи**: $task_id

## Результаты Review

$review_results_block
REJECTION_CTX
            
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
}

source_functions
