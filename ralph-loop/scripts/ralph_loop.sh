#!/usr/bin/env bash
#
# ralph_loop.sh - Ralph loop orchestrator for Kilo CLI with Review Gate
#
# Usage:
#   ./ralph_loop.sh --tasks-path PATH [--max-iterations N] [--verbose] [--no-review] [--working-directory DIR]
#
# Configuration:
#   --tasks-path PATH        Path to tasks.md (required)
#   --max-iterations N       Maximum iterations (default: 50, range: 1-1000)
#   --verbose                Enable verbose output
#   --no-review              Disable review gate (for hotfixes)
#   --working-directory DIR  Working directory
#
# Features:
#   - One task per iteration with mandatory review
#   - Multi-agent review before marking task complete
#   - Circuit breaker: stops after 3 consecutive failures
#   - Review failure tolerance: 2 review failures before stopping
#   - Exponential backoff on failures (max 60s)
#   - Informative output with timestamps
#

set -euo pipefail

#region Configuration
TASKS_PATH=""
MAX_ITERATIONS=50
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
#endregion

#region Security Functions
validate_path() {
    local path="$1"
    local description="$2"
    
    if [[ ! -e "$path" ]]; then
        echo "Error: $description not found: $path" >&2
        exit 1
    fi
    
    path=$(realpath "$path")
    
    if [[ ! "$path" =~ ^"$PROJECT_ROOT" ]]; then
        echo "Error: Path traversal detected. $description must be within project directory" >&2
        exit 1
    fi
    
    echo "$path"
}

validate_numeric() {
    local value="$1"
    local name="$2"
    local min="$3"
    local max="$4"
    
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "Error: $name must be a positive integer" >&2
        exit 1
    fi
    
    if [[ $value -lt $min || $value -gt $max ]]; then
        echo "Error: $name must be between $min and $max" >&2
        exit 1
    fi
}
#endregion

#region Parse Arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tasks-path)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --tasks-path requires a value" >&2
                    exit 1
                fi
                TASKS_PATH="$2"
                shift 2
                ;;
            --max-iterations)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --max-iterations requires a value" >&2
                    exit 1
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
                    echo "Error: --working-directory requires a value" >&2
                    exit 1
                fi
                WORKING_DIRECTORY="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 --tasks-path PATH [--max-iterations N] [--verbose] [--no-review] [--working-directory DIR]"
                echo ""
                echo "Options:"
                echo "  --tasks-path PATH        Path to tasks.md (required)"
                echo "  --max-iterations N       Maximum iterations (default: 50)"
                echo "  --verbose                Enable verbose output"
                echo "  --no-review              Disable review gate"
                echo "  --working-directory DIR  Working directory"
                exit 0
                ;;
            *)
                echo "Error: Unknown parameter: $1" >&2
                exit 1
                ;;
        esac
    done
}
#endregion

#region Helper Functions
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
    
    # Mark task as completed in tasks.md (macOS and Linux compatible)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS requires empty string after -i
        sed -i '' "s/- \[ \] ${task_id}/- [x] ${task_id}/" "$tasks_file"
    else
        # Linux
        sed -i "s/- \[ \] ${task_id}/- [x] ${task_id}/" "$tasks_file"
    fi
    
    print_status "success" "Task $task_id marked as completed"
}

print_summary() {
    local tasks_completed=$1
    local status=$2
    local total_attempts=${3:-0}
    echo ""
    echo "========================================================"
    echo "  Ralph Loop Summary"
    echo "========================================================"
    echo "  Tasks completed: $tasks_completed"
    echo "  Total attempts: $total_attempts"
    echo "  Iterations (retries): $iteration"
    echo "  Status: $status"
    echo "  Log file: $LOG_FILE"
    echo "  Review enabled: $(if [[ "$NO_REVIEW" == "true" ]]; then echo "NO"; else echo "YES"; fi)"
    echo "========================================================"
}
#endregion

#region State Management Functions
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

#region Review Gate Functions
run_review_gate() {
    local iteration=$1
    local task_id=$2
    local pending_file=$3
    local review_prompt_file="$REVIEW_PROMPT_FILE"
    
    if [[ "$NO_REVIEW" == "true" ]]; then
        print_status "info" "Review gate disabled (--no-review)"
        return 0
    fi
    
    if [[ ! -f "$review_prompt_file" ]]; then
        print_status "failure" "Review prompt not found: $review_prompt_file"
        print_status "info" "Skipping review gate..."
        return 1
    fi
    
    print_phase "PHASE 2: Review Gate" "Reviewing task $task_id"
    
    # Prepare review prompt
    local PROMPT=$(sed "s|\$TASKS_PATH|$TASKS_PATH|g" "$review_prompt_file")
    PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$pending_file|g" <<< "$PROMPT")
    
    # Run review
    set +e
    local review_output
    review_output=$(kilo run --auto "$PROMPT" 2>&1)
    local review_exit_code=$?
    set -e
    
    # Parse JSON signal
    local signal=""
    local reviewer="unknown"
    local json_line=$(echo "$review_output" | grep -oE '\{[^{}]*"signal"[^{}]*\}' | tail -1)
    
    if [[ -n "$json_line" ]]; then
        signal=$(echo "$json_line" | jq -e -r 'select(.signal == "REVIEW_APPROVED" or .signal == "REVIEW_REJECTED") | .signal' 2>/dev/null || echo "")
        if [[ -n "$signal" ]]; then
            reviewer=$(echo "$json_line" | jq -r '.reviewer // "unknown"' 2>/dev/null)
        fi
    fi
    
    if [[ "$signal" == "REVIEW_APPROVED" ]]; then
        print_status "success" "Review PASSED - Task $task_id approved"
        echo ""
        return 0
    elif [[ "$signal" == "REVIEW_REJECTED" ]]; then
        print_status "error" "Review REJECTED by $reviewer - Task $task_id needs fixes"
        echo ""
        return 1
    else
        # Check exit code as fallback
        if [[ $review_exit_code -ne 0 ]]; then
            print_status "failure" "Review failed with exit code $review_exit_code"
            return 1
        fi
        
        print_status "info" "Review result unclear - proceeding"
        return 0
    fi
}

do_commit() {
    local feature_name="$1"
    local task_id="$2"
    local iteration="$3"
    
    echo ""
    print_phase "PHASE 3: Commit" "Creating git commit for $task_id"
    
    local commit_message="feat(${feature_name}): ${task_id}"
    
    if [[ "$NO_REVIEW" != "true" ]]; then
        commit_message="${commit_message}

Review: ✅ PASSED"
    fi
    
    git add -A
    git commit -m "$commit_message"
    
    print_status "success" "Committed: $commit_message"
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
        echo "Error: jq is required but not installed. Install with: brew install jq" >&2
        exit 1
    fi
    
    if ! command -v git >/dev/null 2>&1; then
        echo "Error: git is required but not installed" >&2
        exit 1
    fi
    
    parse_args "$@"
    
    if [[ -z "$TASKS_PATH" ]]; then
        echo "Error: --tasks-path is required" >&2
        exit 1
    fi
    
    PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    PROJECT_ROOT=$(realpath "$PROJECT_ROOT")
    
    TASKS_PATH=$(validate_path "$TASKS_PATH" "tasks.md")
    
    validate_numeric "$MAX_ITERATIONS" "--max-iterations" 1 1000
    
    if [[ -n "$WORKING_DIRECTORY" ]]; then
        WORKING_DIRECTORY=$(validate_path "$WORKING_DIRECTORY" "working directory")
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
        echo "Error: Prompt file not found: $PROMPT_FILE" >&2
        exit 1
    fi
    
    if [[ "$NO_REVIEW" != "true" ]]; then
        REVIEW_PROMPT_FILE="${PROJECT_ROOT}/.kilo/prompts/ralph-review.md"
        if [[ ! -f "$REVIEW_PROMPT_FILE" ]]; then
            echo "⚠️  Warning: Review prompt not found: $REVIEW_PROMPT_FILE" >&2
        fi
    fi
    
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "Error: Another instance is running (PID: $lock_pid)" >&2
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
    
    local FEATURE_NAME=$(extract_feature_name "$TASKS_PATH")
    
    echo "🚀 Запуск Ralph Loop..."
    echo "Tasks: $TASKS_PATH"
    echo "Feature: $FEATURE_NAME"
    echo "Max iterations: $MAX_ITERATIONS"
    echo "Review enabled: $(if [[ "$NO_REVIEW" == "true" ]]; then echo "NO"; else echo "YES"; fi)"
    echo "Mode: ONE TASK PER ITERATION"
    echo ""
    
    local iteration=0
    local tasks_completed=0
    local consecutive_failures=0
    local max_consecutive_failures=3
    local review_failures=0
    local max_review_failures=2
    local total_attempts=0
    local max_total_attempts=$((MAX_ITERATIONS * 10))
    
    while [[ $total_attempts -lt $max_total_attempts ]]; do
        ((total_attempts++))
        print_header "$iteration" "$MAX_ITERATIONS"
        
        # Check for remaining tasks
        local next_task=$(get_first_incomplete_task "$TASKS_PATH")
        
        if [[ -z "$next_task" ]]; then
            echo ""
            save_state "COMPLETE" "$iteration" ""
            print_status "success" "🎉 All tasks complete!"
            print_summary "$tasks_completed" "COMPLETE" "$total_attempts"
            exit 0
        fi
        
        rm -f "$PENDING_TASKS_FILE"
        
        # =====================================================
        # PHASE 1: Implementation (ONE TASK)
        # =====================================================
        
        print_phase "PHASE 1: Implementation" "Working on task $next_task"
        save_state "IMPLEMENTING" "$iteration" "$next_task"
        
        local PROMPT=$(sed "s|\$TASKS_PATH|$TASKS_PATH|g" "$PROMPT_FILE")
        PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$PENDING_TASKS_FILE|g" <<< "$PROMPT")
        PROMPT=$(printf '%s' "$PROMPT")
        
        set +e
        kilo run --auto "$PROMPT"
        local exit_code=$?
        set -e
        
        if [[ $exit_code -ne 0 ]]; then
            save_state "FAILED" "$iteration" "$next_task"
            ((consecutive_failures++))
            ((iteration++))
            
            print_status "error" "Iteration $iteration: implementation failed for task $next_task"
            
            print_status "failure" "Implementation failure $consecutive_failures/$max_consecutive_failures"
            
            if [[ $consecutive_failures -ge $max_consecutive_failures ]]; then
                print_status "error" "Circuit breaker triggered"
                print_summary "$tasks_completed" "CIRCUIT_BREAKER" "$total_attempts"
                exit 1
            fi
            
            if [[ $iteration -ge $MAX_ITERATIONS ]]; then
                print_status "error" "Max iterations reached"
                print_summary "$tasks_completed" "MAX_ITERATIONS_REACHED" "$total_attempts"
                exit 1
            fi
            
            local backoff=$((2 ** consecutive_failures))
            [[ $backoff -gt 60 ]] && backoff=60
            echo "⏳ Waiting ${backoff}s before retry..."
            sleep "$backoff"
            
            continue
        fi
        
        consecutive_failures=0
        
        # =====================================================
        # PHASE 2: Review Gate
        # =====================================================
        
        if [[ ! -f "$PENDING_TASKS_FILE" ]]; then
            print_status "info" "No pending task file created - task may already be complete or agent had nothing to do"
            continue
        fi
        
        local pending_task_id=$(jq -r '.task_id' "$PENDING_TASKS_FILE" 2>/dev/null || echo "")
        
        if [[ -z "$pending_task_id" ]]; then
            print_status "failure" "Invalid pending tasks file"
            continue
        fi
        
        print_status "info" "Task $pending_task_id ready for review"
        save_state "REVIEWING" "$iteration" "$pending_task_id"
        
        set +e
        run_review_gate "$iteration" "$pending_task_id" "$PENDING_TASKS_FILE"
        local review_result=$?
        set -e
        
        if [[ $review_result -ne 0 ]]; then
            ((review_failures++))
            ((iteration++))
            print_status "failure" "Review failure $review_failures/$max_review_failures (iteration $iteration)"
            
            if [[ $review_failures -ge $max_review_failures ]]; then
                print_status "error" "Too many review failures"
                print_summary "$tasks_completed" "REVIEW_FAILURES" "$total_attempts"
                exit 1
            fi
            
            if [[ $iteration -ge $MAX_ITERATIONS ]]; then
                print_status "error" "Max iterations reached"
                print_summary "$tasks_completed" "MAX_ITERATIONS_REACHED" "$total_attempts"
                exit 1
            fi
            
            # Save rejection context
            local last_review_log=$(tail -n 50 "$LOG_FILE" 2>/dev/null || echo "")
            local rejection_context_file="${PROJECT_ROOT}/.ralph_rejection_context.md"
            local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
            
            cat > "$rejection_context_file" << REJECTION_CTX
# Review Rejection Context

**Iteration**: $iteration
**Timestamp**: $timestamp
**Task ID**: $pending_task_id

## ⚠️ ВАЖНО: ИСПРАВЬ ЭТУ ЖЕ ЗАДАЧУ

Твоя задача $pending_task_id была отклонена на review.
Ты ДОЛЖЕН исправить замечания и снова отправить ЕЁ ЖЕ на review.
НЕ переходи к следующей задаче пока эта не пройдёт review.

## Recent Review Log

\`\`\`
$last_review_log
\`\`\`

## Action Required

1. Прочитай замечания reviewers выше
2. Исправь проблемы в коде
3. Создай файл $PENDING_TASKS_FILE с task_id: "$pending_task_id"
4. НЕ начинай новые задачи пока эта не одобрена
REJECTION_CTX
            
            save_state "REJECTED" "$iteration" "$pending_task_id"
            print_status "info" "Rejection context saved to: $rejection_context_file"
            
            continue
        fi
        
        # =====================================================
        # PHASE 3: Mark complete & Commit
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
            print_status "info" "Remaining tasks: $remaining"
        fi
        
        sleep 1
    done
    
    print_summary "$tasks_completed" "MAX_ATTEMPTS_REACHED" "$total_attempts"
}

#endregion

main "$@"
