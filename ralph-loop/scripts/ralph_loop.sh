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
#   - Two-phase approach: Implementation → Review → Commit
#   - Multi-agent review before commit (review-analyst, review-security, etc.)
#   - Circuit breaker: stops after 3 consecutive failures
#   - Review failure tolerance: 2 review failures before stopping
#   - Exponential backoff on failures (max 60s)
#   - Informative output with timestamps
#   - Safe parameter validation (command injection, path traversal protection)
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
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$phase: $message"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

print_status() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo "✅ $message"
    elif [[ "$status" == "failure" ]]; then
        echo "⚠️  $message"
    elif [[ "$status" == "error" ]]; then
        echo "❌ $message"
    elif [[ "$status" == "info" ]]; then
        echo "ℹ️  $message"
    fi
}

get_incomplete_task_count() {
    local tasks_file="$1"
    local count=0
    
    if [[ -f "$tasks_file" ]]; then
        count=$(grep -c "^\s*-\s*\[ \]" "$tasks_file" 2>/dev/null || echo "0")
    fi
    
    echo "$count"
}

get_completed_task_count() {
    local tasks_file="$1"
    local count=0
    
    if [[ -f "$tasks_file" ]]; then
        count=$(grep -c "^\s*-\s*\[x\]" "$tasks_file" 2>/dev/null || echo "0")
    fi
    
    echo "$count"
}

print_summary() {
    local iterations_run=$1
    local status=$2
    echo ""
    echo "========================================================"
    echo "  Ralph Loop Summary"
    echo "========================================================"
    echo "  Iterations run: $iterations_run"
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
    local user_story="$3"
    
    cat > "$STATE_FILE" << EOF
{
  "state": "$state",
  "iteration": $iteration,
  "current_user_story": "$user_story",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pid": $$
}
EOF
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo '{"state": "IDLE", "iteration": 0, "current_user_story": ""}'
    fi
}

get_state_value() {
    local key="$1"
    load_state | jq -r ".$key" 2>/dev/null || echo ""
}
#endregion

#region Review Gate Functions
run_review_gate() {
    local iteration=$1
    local tasks_path=$2
    local review_prompt_file="$PROJECT_ROOT/$REVIEW_PROMPT_FILE"
    
    if [[ "$NO_REVIEW" == "true" ]]; then
        print_status "info" "Review gate disabled (--no-review)"
        return 0
    fi
    
    if [[ ! -f "$review_prompt_file" ]]; then
        print_status "failure" "Review prompt not found: $review_prompt_file"
        print_status "info" "Skipping review gate..."
        return 0
    fi
    
    print_phase "PHASE 2: Review Gate" "Running multi-agent review"
    
    # Prepare review prompt with tasks path
    local PROMPT=$(sed "s|\$TASKS_PATH|$tasks_path|g" "$review_prompt_file")
    
    # Run review
    set +e
    local review_output
    review_output=$(kilo run --auto "$PROMPT" 2>&1)
    local review_exit_code=$?
    set -e
    
    # Parse JSON signal with validation
    local signal=""
    local reviewer="unknown"
    
    # Extract last JSON object from output
    local json_line=$(echo "$review_output" | grep -oE '\{[^{}]*"signal"[^{}]*\}' | tail -1)
    
    if [[ -n "$json_line" ]]; then
        # Validate JSON and extract signal with whitelist
        signal=$(echo "$json_line" | jq -e -r 'select(.signal == "REVIEW_APPROVED" or .signal == "REVIEW_REJECTED" or .signal == "USER_STORY_COMPLETE" or .signal == "COMPLETE") | .signal' 2>/dev/null || echo "")
        
        if [[ -n "$signal" ]]; then
            reviewer=$(echo "$json_line" | jq -r '.reviewer // "unknown"' 2>/dev/null)
        fi
    fi
    
    if [[ "$signal" == "REVIEW_APPROVED" ]]; then
        print_status "success" "Review PASSED - Commit allowed"
        echo ""
        return 0
    elif [[ "$signal" == "REVIEW_REJECTED" ]]; then
        print_status "error" "Review REJECTED by $reviewer - Commit blocked"
        echo ""
        # Log rejection
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] REVIEW_REJECTED by $reviewer at iteration $iteration" >> "$LOG_FILE"
        return 1
    else
        # Fallback: check for old signal format
        if echo "$review_output" | grep -q '<promise>REVIEW_APPROVED</promise>'; then
            print_status "success" "Review PASSED (legacy format) - Commit allowed"
            echo ""
            return 0
        elif echo "$review_output" | grep -q '<promise>REVIEW_REJECTED</promise>'; then
            print_status "error" "Review REJECTED (legacy format) - Commit blocked"
            echo ""
            return 1
        fi
        
        # No clear signal - check exit code
        if [[ $review_exit_code -ne 0 ]]; then
            print_status "failure" "Review failed with exit code $review_exit_code"
            return 1
        fi
        
        print_status "failure" "Review result unclear (no signal found)"
        print_status "info" "Proceeding with caution..."
        echo ""
        return 0
    fi
}

do_commit() {
    local feature_name="$1"
    local iteration="$2"
    local review_passed="$3"
    
    echo ""
    print_phase "PHASE 3: Commit" "Creating git commit"
    
    # Try to use Spec Kit git extension if available
    local git_extension_script="$PROJECT_ROOT/.specify/extensions/git/scripts/bash/auto-commit.sh"
    local commit_message="feat(${feature_name}): User story iteration ${iteration}"
    
    # Add review status to commit message
    if [[ "$NO_REVIEW" != "true" ]]; then
        if [[ "$review_passed" == "true" ]]; then
            commit_message="${commit_message}

Review: ✅ PASSED (all reviewers approved)"
        else
            commit_message="${commit_message}

Review: ⏭️ SKIPPED (--no-review)"
        fi
    fi
    
    # Write commit message to temp file for git extension
    local commit_msg_file=$(mktemp)
    echo "$commit_message" > "$commit_msg_file"
    
    if [[ -x "$git_extension_script" ]]; then
        # Use Spec Kit git extension (respects hooks and config)
        print_status "info" "Using Spec Kit git extension"
        GIT_COMMIT_MESSAGE="$commit_message" "$git_extension_script" "after_implement" || {
            # Fallback to direct git if extension fails
            print_status "info" "Git extension failed, using direct git commit"
            git add -A
            git commit -F "$commit_msg_file"
        }
    else
        # Direct git commit (no Spec Kit integration) - use file for safety
        git add -A
        git commit -F "$commit_msg_file"
    fi
    
    rm -f "$commit_msg_file"
    
    print_status "success" "Committed: $commit_message"
}

extract_feature_name() {
    local tasks_path="$1"
    # Extract feature name from path like "specs/001-feature-name/tasks.md"
    local dirname=$(dirname "$tasks_path")
    local basename=$(basename "$dirname")
    echo "$basename"
}
#endregion

#region Main
main() {
    # Check required dependencies
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
    
    # Create log and state files with restrictive permissions
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    touch "$STATE_FILE" && chmod 600 "$STATE_FILE"
    
    PROMPT_FILE="${PROJECT_ROOT}/${PROMPT_FILE}"
    if [[ ! -f "$PROMPT_FILE" ]]; then
        echo "Error: Prompt file not found: $PROMPT_FILE" >&2
        exit 1
    fi
    
    # Review prompt is optional (can be disabled with --no-review)
    if [[ "$NO_REVIEW" != "true" ]]; then
        REVIEW_PROMPT_FILE="${PROJECT_ROOT}/${REVIEW_PROMPT_FILE}"
        if [[ ! -f "$REVIEW_PROMPT_FILE" ]]; then
            echo "⚠️  Warning: Review prompt not found: $REVIEW_PROMPT_FILE" >&2
            echo "⚠️  Review will be skipped" >&2
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
    
    # Extract feature name for commit messages
    local FEATURE_NAME=$(extract_feature_name "$TASKS_PATH")
    
    echo "🚀 Запуск Ralph Loop..."
    echo "Tasks: $TASKS_PATH"
    echo "Feature: $FEATURE_NAME"
    echo "Max iterations: $MAX_ITERATIONS"
    echo "Review enabled: $(if [[ "$NO_REVIEW" == "true" ]]; then echo "NO"; else echo "YES"; fi)"
    echo "Verbose: $VERBOSE"
    echo ""
    
    local iteration=1
    local consecutive_failures=0
    local max_consecutive_failures=3
    local review_failures=0
    local max_review_failures=2
    
    while [[ $iteration -le $MAX_ITERATIONS ]]; do
        print_header "$iteration" "$MAX_ITERATIONS"
        
        # Snapshot completed tasks before this iteration
        local tasks_before_iteration=$(get_completed_task_count "$TASKS_PATH")
        
        # Save state at start of iteration
        save_state "IMPLEMENTING" "$iteration" ""
        
        # =====================================================
        # PHASE 1: Implementation
        # =====================================================
        
        print_phase "PHASE 1: Implementation" "Running agent to implement tasks"
        
        local PROMPT=$(sed "s|\$TASKS_PATH|$TASKS_PATH|g" "$PROMPT_FILE")
        PROMPT=$(printf '%s' "$PROMPT")
        
        set +e
        kilo run --auto "$PROMPT"
        local exit_code=$?
        set -e
        
        if [[ $exit_code -ne 0 ]]; then
            save_state "FAILED" "$iteration" ""
            ((consecutive_failures++))
            
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: Iteration $iteration implementation failed" >> "$LOG_FILE"
            echo "Exit code: $exit_code" >> "$LOG_FILE"
            
            print_status "failure" "Implementation failure $consecutive_failures/$max_consecutive_failures"
            
            if [[ $consecutive_failures -ge $max_consecutive_failures ]]; then
                print_status "error" "Circuit breaker triggered"
                print_summary "$iteration" "CIRCUIT_BREAKER"
                exit 1
            fi
            
            local backoff=$((2 ** consecutive_failures))
            local max_backoff=60
            [[ $backoff -gt $max_backoff ]] && backoff=$max_backoff
            echo "⏳ Waiting ${backoff}s before retry..."
            sleep "$backoff"
            
            ((iteration++))
            continue
        else
            consecutive_failures=0
            save_state "REVIEWING" "$iteration" ""
            print_status "success" "Implementation completed"
        fi
        
        # =====================================================
        # PHASE 2: Review Gate
        # =====================================================
        
        # Check if NEW tasks were completed in this iteration
        local tasks_after=$(get_completed_task_count "$TASKS_PATH")
        local tasks_before="${tasks_before_iteration:-0}"
        local new_tasks_completed=$((tasks_after - tasks_before))
        
        if [[ $new_tasks_completed -gt 0 ]]; then
            # New tasks were completed in this iteration, run review
            set +e
            run_review_gate "$iteration" "$TASKS_PATH"
            local review_result=$?
            set -e
            
            if [[ $review_result -ne 0 ]]; then
                ((review_failures++))
                print_status "failure" "Review failure $review_failures/$max_review_failures"
                
                if [[ $review_failures -ge $max_review_failures ]]; then
                    print_status "error" "Too many review failures"
                    print_summary "$iteration" "REVIEW_FAILURES"
                    exit 1
                fi
                
                # Save rejection context for next iteration
                local last_review_log=$(tail -n 50 "$LOG_FILE" 2>/dev/null || echo "")
                local rejection_context_file="${PROJECT_ROOT}/.ralph_rejection_context.md"
                
                cat > "$rejection_context_file" << EOF
# Review Rejection Context

**Iteration**: $iteration
**Timestamp**: $(date +'%Y-%m-%d %H:%M:%S')

## Recent Review Log

\`\`\`
$last_review_log
\`\`\`

## Action Required

Fix the issues identified by reviewers and continue implementation.
EOF
                
                save_state "REJECTED" "$iteration" ""
                print_status "info" "Skipping commit, issues need to be fixed"
                print_status "info" "Rejection context saved to: $rejection_context_file"
                print_status "info" "Agent should read this file in next iteration"
                
                ((iteration++))
                continue
            fi
            
            save_state "COMMITTING" "$iteration" ""
            review_failures=0
            
            # =====================================================
            # PHASE 3: Commit (only if review passed)
            # =====================================================
            
            do_commit "$FEATURE_NAME" "$iteration" "true"
            save_state "IDLE" "$iteration" ""
        else
            # No tasks completed in this iteration
            save_state "IDLE" "$iteration" ""
            print_status "info" "No tasks completed in this iteration"
        fi
        
        # =====================================================
        # Check Completion
        # =====================================================
        
        local remaining_tasks=$(get_incomplete_task_count "$TASKS_PATH")
        if [[ "$remaining_tasks" -eq 0 ]]; then
            echo ""
            save_state "COMPLETE" "$iteration" ""
            print_status "success" "🎉 All tasks complete!"
            print_summary "$iteration" "COMPLETE"
            exit 0
        fi
        
        if [[ "$VERBOSE" == "true" ]]; then
            echo ""
            print_status "info" "Remaining tasks: $remaining_tasks"
        fi
        
        ((iteration++))
        sleep 2
    done
    
    print_summary "$((iteration - 1))" "MAX_ITERATIONS_REACHED"
}

#endregion

main "$@"
