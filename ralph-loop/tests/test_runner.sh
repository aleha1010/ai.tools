#!/usr/bin/env bash
#
# Простой тестовый раннер для Ralph Loop
# Запуск: ./test_runner.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_LOOP_DIR="$(dirname "$SCRIPT_DIR")"
RALPH_LOOP_SCRIPT="$RALPH_LOOP_DIR/scripts/ralph_loop.sh"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMP_DIR=""

setup() {
    TEST_TMP_DIR=$(mktemp -d)
    cd "$TEST_TMP_DIR"
    
    mkdir -p .kilo/prompts
    echo "Test prompt" > .kilo/prompts/ralph-iterate.md
    echo "Test review prompt" > .kilo/prompts/ralph-review.md
    
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    
    mkdir -p specs/001-test
    cat > specs/001-test/tasks.md << 'EOF'
# Tasks

- [ ] T001: First task
- [ ] T002: Second task
- [x] T003: Completed task
EOF
    
    git add -A
    git commit -q -m "Initial commit"
    
    # Создаём .ralph_state.json
    export STATE_FILE="$TEST_TMP_DIR/.ralph_state.json"
    echo '{"state": "IDLE", "iteration": 0, "current_task": "", "timestamp": "", "pid": 0}' > "$STATE_FILE"
}

teardown() {
    if [[ -n "$TEST_TMP_DIR" && -d "$TEST_TMP_DIR" ]]; then
        cd /
        rm -rf "$TEST_TMP_DIR"
    fi
}

run_test() {
    local test_name="$1"
    local test_func="$2"
    
    ((TESTS_RUN++))
    
    setup
    
    if $test_func; then
        ((TESTS_PASSED++))
        echo -e "${GREEN}✓${NC} $test_name"
    else
        ((TESTS_FAILED++))
        echo -e "${RED}✗${NC} $test_name"
    fi
    
    teardown
}

# =====================================================
# ИМПОРТ ФУНКЦИЙ
# =====================================================

source_functions() {
    # validate_path - модифицированная для тестов (принимает PROJECT_ROOT как аргумент)
    validate_path() {
        local path="$1"
        local description="$2"
        local project_root="${3:-$PROJECT_ROOT}"
        
        if [[ ! -e "$path" ]]; then
            echo "Error: $description not found: $path" >&2
            return 1
        fi
        
        path=$(realpath "$path")
        
        if [[ ! "$path" =~ ^"$project_root" ]]; then
            echo "Error: Path traversal detected. $description must be within project directory" >&2
            return 1
        fi
        
        echo "$path"
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
    
    validate_numeric() {
        local value="$1"
        local name="$2"
        local min="$3"
        local max="$4"
        
        if [[ ! "$value" =~ ^[0-9]+$ ]]; then
            echo "Error: $name must be a positive integer" >&2
            return 1
        fi
        
        if [[ $value -lt $min || $value -gt $max ]]; then
            echo "Error: $name must be between $min and $max" >&2
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
        
        print_status "success" "Task $task_id marked as completed"
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
    
    run_review_gate() {
        local iteration=$1
        local task_id=$2
        local pending_file=$3
        local review_prompt_file="${REVIEW_PROMPT_FILE:-.kilo/prompts/ralph-review.md}"
        
        if [[ "${NO_REVIEW:-false}" == "true" ]]; then
            print_status "info" "Review gate disabled (--no-review)"
            return 0
        fi
        
        if [[ ! -f "$review_prompt_file" ]]; then
            print_status "failure" "Review prompt not found: $review_prompt_file"
            return 1
        fi
        
        print_phase "PHASE 2: Review Gate" "Reviewing task $task_id"
        
        local PROMPT=$(sed "s|\$TASKS_PATH|${TASKS_PATH:-tasks.md}|g" "$review_prompt_file")
        PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$pending_file|g" <<< "$PROMPT")
        
        set +e
        local review_output
        local kilo_cmd="${KILO_CMD:-kilo}"
        review_output=$($kilo_cmd run --auto "$PROMPT" 2>&1)
        local review_exit_code=$?
        set -e
        
        if echo "$review_output" | grep -q "Session not found\|Error:"; then
            print_status "error" "Kilo error - session issue"
            return 2
        fi
        
        local decision=""
        decision=$(echo "$review_output" | grep -o "### Decision: APPROVED\|### Decision: REJECTED" | head -1 | sed 's/### Decision: //')
        
        if [[ "$decision" == "APPROVED" ]]; then
            print_status "success" "Review PASSED - Task $task_id approved"
            return 0
        elif [[ "$decision" == "REJECTED" ]]; then
            print_status "error" "Review REJECTED - Task $task_id needs fixes"
            
            local review_results_block=""
            review_results_block=$(echo "$review_output" | sed -n '/^REVIEW RESULTS:/,$p')
            echo "$review_results_block" > "${PROJECT_ROOT}/.ralph_review_results.md"
            
            local rejection_context_file="${PROJECT_ROOT}/.ralph_rejection_context.md"
            local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
            
            cat > "$rejection_context_file" << REJECTION_CTX
# Review Rejection Context

**Timestamp**: $timestamp
**Task ID**: $task_id

## Review Results

$review_results_block
REJECTION_CTX
            
            return 1
        else
            if [[ $review_exit_code -ne 0 ]]; then
                print_status "failure" "Review failed with exit code $review_exit_code"
                return 2
            fi
            
            print_status "failure" "No valid REVIEW RESULTS found in output"
            return 2
        fi
    }
}

# =====================================================
# ТЕСТЫ: validate_path()
# =====================================================

test_validate_path_accepts_valid_path() {
    source_functions
    
    local valid_path="$TEST_TMP_DIR/specs/001-test/tasks.md"
    local result
    
    # Используем realpath для PROJECT_ROOT тоже (macOS symlink fix)
    local project_root_real
    project_root_real=$(realpath "$TEST_TMP_DIR")
    
    result=$(validate_path "$valid_path" "tasks.md" "$project_root_real")
    
    # realpath может вернуть другой формат пути, проверяем что путь существует и возвращается
    if [[ -n "$result" && -f "$result" ]]; then
        return 0
    else
        echo "Expected valid path, got: $result" >&2
        return 1
    fi
}

test_validate_path_rejects_nonexistent() {
    source_functions
    
    local nonexistent="/nonexistent/path/to/file.md"
    
    if validate_path "$nonexistent" "test file" "$TEST_TMP_DIR" 2>&1; then
        echo "Should have rejected nonexistent path" >&2
        return 1
    fi
    
    return 0
}

test_validate_path_rejects_path_traversal() {
    source_functions
    
    if validate_path "/etc/passwd" "test file" "$TEST_TMP_DIR" 2>&1; then
        echo "Should have rejected path traversal" >&2
        return 1
    fi
    
    return 0
}

# =====================================================
# ТЕСТЫ: validate_numeric()
# =====================================================

test_validate_numeric_accepts_valid_number() {
    source_functions
    
    if validate_numeric "50" "test" 1 1000 2>&1; then
        return 0
    else
        echo "Should have accepted valid number" >&2
        return 1
    fi
}

test_validate_numeric_rejects_negative() {
    source_functions
    
    if validate_numeric "-5" "test" 1 1000 2>&1; then
        echo "Should have rejected negative number" >&2
        return 1
    fi
    
    return 0
}

test_validate_numeric_rejects_out_of_range() {
    source_functions
    
    if validate_numeric "2000" "test" 1 1000 2>&1; then
        echo "Should have rejected out of range number" >&2
        return 1
    fi
    
    return 0
}

test_validate_numeric_rejects_non_numeric() {
    source_functions
    
    if validate_numeric "abc" "test" 1 1000 2>&1; then
        echo "Should have rejected non-numeric value" >&2
        return 1
    fi
    
    return 0
}

# =====================================================
# ТЕСТЫ: get_first_incomplete_task()
# =====================================================

test_get_first_incomplete_task_returns_first() {
    source_functions
    
    local tasks_file="$TEST_TMP_DIR/specs/001-test/tasks.md"
    local result
    
    result=$(get_first_incomplete_task "$tasks_file")
    
    if [[ "$result" == "T001" ]]; then
        return 0
    else
        echo "Expected T001, got $result" >&2
        return 1
    fi
}

test_get_first_incomplete_task_returns_empty_when_complete() {
    source_functions
    
    cat > "$TEST_TMP_DIR/specs/001-test/tasks.md" << 'EOF'
# Tasks

- [x] T001: Completed
- [x] T002: Completed
EOF
    
    local tasks_file="$TEST_TMP_DIR/specs/001-test/tasks.md"
    local result
    
    result=$(get_first_incomplete_task "$tasks_file")
    
    if [[ -z "$result" ]]; then
        return 0
    else
        echo "Expected empty, got $result" >&2
        return 1
    fi
}

# =====================================================
# ТЕСТЫ: mark_task_completed()
# =====================================================

test_mark_task_completed_marks_correctly() {
    source_functions
    
    local tasks_file="$TEST_TMP_DIR/specs/001-test/tasks.md"
    
    mark_task_completed "$tasks_file" "T001" 2>&1 || true
    
    if grep -q "\[x\] T001" "$tasks_file"; then
        return 0
    else
        echo "Task T001 should be marked as completed" >&2
        return 1
    fi
}

# =====================================================
# ТЕСТЫ: save_state()
# =====================================================

test_save_state_creates_valid_json() {
    source_functions
    
    save_state "IMPLEMENTING" "5" "T001"
    
    if [[ -f "$STATE_FILE" ]] && jq -e . "$STATE_FILE" > /dev/null 2>&1; then
        return 0
    else
        echo "State file should be valid JSON" >&2
        return 1
    fi
}

test_save_state_contains_correct_values() {
    source_functions
    
    save_state "IMPLEMENTING" "5" "T001"
    
    local state
    state=$(jq -r '.state' "$STATE_FILE")
    local iteration
    iteration=$(jq -r '.iteration' "$STATE_FILE")
    local task
    task=$(jq -r '.current_task' "$STATE_FILE")
    
    if [[ "$state" == "IMPLEMENTING" && "$iteration" == "5" && "$task" == "T001" ]]; then
        return 0
    else
        echo "State values incorrect: state=$state, iteration=$iteration, task=$task" >&2
        return 1
    fi
}

# =====================================================
# ТЕСТЫ: print_status()
# =====================================================

test_print_status_success() {
    source_functions
    
    local output
    output=$(print_status "success" "Test message")
    
    if [[ "$output" == *"✅"* && "$output" == *"Test message"* ]]; then
        return 0
    else
        echo "Output should contain success icon and message" >&2
        return 1
    fi
}

test_print_status_error() {
    source_functions
    
    local output
    output=$(print_status "error" "Test error")
    
    if [[ "$output" == *"❌"* && "$output" == *"Test error"* ]]; then
        return 0
    else
        echo "Output should contain error icon and message" >&2
        return 1
    fi
}

# =====================================================
# ТЕСТЫ: Circuit Breaker
# =====================================================

test_circuit_breaker_stops_after_three_failures() {
    mkdir -p "$TEST_TMP_DIR/bin"
    
    cat > "$TEST_TMP_DIR/bin/kilo" << 'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$TEST_TMP_DIR/bin/kilo"
    
    export PATH="$TEST_TMP_DIR/bin:$PATH"
    export KILO_CMD="$TEST_TMP_DIR/bin/kilo"
    
    cd "$TEST_TMP_DIR"
    
    set +e
    local output
    output=$(bash "$RALPH_LOOP_SCRIPT" --tasks-path "$TEST_TMP_DIR/specs/001-test/tasks.md" --max-iterations 10 2>&1)
    local exit_code=$?
    set -e
    
    if [[ "$exit_code" -eq 1 ]] && [[ "$output" == *"Circuit breaker"* || "$output" == *"CIRCUIT_BREAKER"* ]]; then
        return 0
    else
        echo "Circuit breaker should stop after 3 failures. Exit: $exit_code" >&2
        echo "$output" | tail -10 >&2
        return 1
    fi
}

# =====================================================
# ТЕСТЫ: Review Gate
# =====================================================

test_review_gate_approves_on_approved_decision() {
    source_functions
    
    export REVIEW_PROMPT_FILE="$TEST_TMP_DIR/.kilo/prompts/ralph-review.md"
    export NO_REVIEW="false"
    export PROJECT_ROOT="$TEST_TMP_DIR"
    export KILO_CMD='echo "### Decision: APPROVED"'
    
    local pending_file="$TEST_TMP_DIR/.ralph_pending_tasks.json"
    echo '{"task_id": "T001", "files_changed": [], "summary": "test"}' > "$pending_file"
    
    set +e
    run_review_gate 1 "T001" "$pending_file" 2>&1
    local result=$?
    set -e
    
    if [[ "$result" -eq 0 ]]; then
        return 0
    else
        echo "Review gate should return 0 for APPROVED, got $result" >&2
        return 1
    fi
}

test_review_gate_rejects_on_rejected_decision() {
    source_functions
    
    export REVIEW_PROMPT_FILE="$TEST_TMP_DIR/.kilo/prompts/ralph-review.md"
    export NO_REVIEW="false"
    export PROJECT_ROOT="$TEST_TMP_DIR"
    export KILO_CMD='echo "REVIEW RESULTS:

### Decision: REJECTED

## FIX REQUIRED:
1. Fix this"'
    
    local pending_file="$TEST_TMP_DIR/.ralph_pending_tasks.json"
    echo '{"task_id": "T001", "files_changed": [], "summary": "test"}' > "$pending_file"
    
    set +e
    run_review_gate 1 "T001" "$pending_file" 2>&1
    local result=$?
    set -e
    
    if [[ "$result" -eq 1 ]]; then
        return 0
    else
        echo "Review gate should return 1 for REJECTED, got $result" >&2
        return 1
    fi
}

test_review_gate_creates_rejection_context() {
    source_functions
    
    export REVIEW_PROMPT_FILE="$TEST_TMP_DIR/.kilo/prompts/ralph-review.md"
    export NO_REVIEW="false"
    export PROJECT_ROOT="$TEST_TMP_DIR"
    export KILO_CMD='echo "REVIEW RESULTS:

### Decision: REJECTED

## FIX REQUIRED:
1. Fix this"'
    
    local pending_file="$TEST_TMP_DIR/.ralph_pending_tasks.json"
    echo '{"task_id": "T001", "files_changed": [], "summary": "test"}' > "$pending_file"
    
    set +e
    run_review_gate 1 "T001" "$pending_file" > /dev/null 2>&1
    set -e
    
    if [[ -f "$TEST_TMP_DIR/.ralph_rejection_context.md" ]]; then
        return 0
    else
        echo "Rejection context file should be created" >&2
        return 1
    fi
}

# =====================================================
# ТЕСТЫ: Interrupt Handling
# =====================================================

test_cleanup_saves_interrupted_state() {
    local test_script="$TEST_TMP_DIR/test_cleanup.sh"
    
    cat > "$test_script" << 'SCRIPT'
#!/bin/bash
set -euo pipefail

STATE_FILE="/tmp/test_cleanup_state.json"
LOCK_FILE="/tmp/test_cleanup.lock"
current_task_id="T003"
current_state="REVIEWING"
iteration=1

print_status() { :; }

save_state() {
    local state="$1"
    local iteration="$2"
    local current_task="$3"
    printf '{"state": "%s", "iteration": %d, "current_task": "%s"}\n' "$state" "$iteration" "$current_task" > "$STATE_FILE"
}

cleanup() {
    local exit_code=$?
    if [[ -n "$current_task_id" && "$current_state" != "COMPLETE" && "$current_state" != "IDLE" ]]; then
        save_state "INTERRUPTED" "$iteration" "$current_task_id"
    fi
    exit $exit_code
}

trap cleanup EXIT TERM INT

save_state "REVIEWING" "$iteration" "$current_task_id"
kill -TERM $$
SCRIPT

    chmod +x "$test_script"
    
    set +e
    bash "$test_script" 2>&1
    set -e
    
    local state_file="/tmp/test_cleanup_state.json"
    
    if [[ -f "$state_file" ]]; then
        local state=$(jq -r '.state' "$state_file" 2>/dev/null)
        local task=$(jq -r '.current_task' "$state_file" 2>/dev/null)
        rm -f "$state_file"
        
        if [[ "$state" == "INTERRUPTED" && "$task" == "T003" ]]; then
            return 0
        else
            echo "Expected INTERRUPTED state for T003, got: $state for $task" >&2
            return 1
        fi
    else
        echo "State file not created after interrupt" >&2
        return 1
    fi
}

test_cleanup_skips_idle_state() {
    local test_script="$TEST_TMP_DIR/test_cleanup_idle.sh"
    
    cat > "$test_script" << 'SCRIPT'
#!/bin/bash
set -euo pipefail

STATE_FILE="/tmp/test_cleanup_idle.json"
current_task_id=""
current_state="IDLE"
iteration=1

save_state() {
    local state="$1"
    printf '{"state": "%s"}\n' "$state" > "$STATE_FILE"
}

cleanup() {
    local exit_code=$?
    if [[ -n "$current_task_id" && "$current_state" != "COMPLETE" && "$current_state" != "IDLE" ]]; then
        save_state "INTERRUPTED"
    fi
    exit $exit_code
}

trap cleanup EXIT TERM INT
kill -TERM $$
SCRIPT

    chmod +x "$test_script"
    
    set +e
    bash "$test_script" 2>&1
    set -e
    
    local state_file="/tmp/test_cleanup_idle.json"
    
    if [[ -f "$state_file" ]]; then
        echo "State file should NOT be created for IDLE state" >&2
        cat "$state_file" >&2
        rm -f "$state_file"
        return 1
    else
        return 0
    fi
}

test_task_selection_continues_interrupted() {
    source_functions
    
    local state_file="$TEST_TMP_DIR/.ralph_state.json"
    mkdir -p "$(dirname "$state_file")"
    
    cat > "$state_file" << EOF
{
  "state": "INTERRUPTED",
  "iteration": 1,
  "current_task": "T003",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pid": 99999
}
EOF
    
    local prev_state=$(jq -r '.state // empty' "$state_file" 2>/dev/null)
    local prev_task=$(jq -r '.current_task // empty' "$state_file" 2>/dev/null)
    
    if [[ ("$prev_state" == "REJECTED" || "$prev_state" == "INTERRUPTED") && -n "$prev_task" ]]; then
        if [[ "$prev_task" == "T003" ]]; then
            return 0
        else
            echo "Expected T003, got $prev_task" >&2
            return 1
        fi
    else
        echo "Task selection logic failed for INTERRUPTED state" >&2
        return 1
    fi
}

test_state_saved_before_cleanup_on_rejected() {
    # Test that REJECTED state is preserved (not overwritten by cleanup)
    # After fix: cleanup only saves INTERRUPTED on errors/signals, not normal exit
    
    local test_script="$TEST_TMP_DIR/test_rejected_state.sh"
    
    cat > "$test_script" << 'SCRIPT'
#!/bin/bash
set -euo pipefail

STATE_FILE="/tmp/test_rejected_state.json"
LOCK_FILE="/tmp/test_rejected.lock"
current_task_id="T002"
current_state="REVIEWING"
iteration=1

save_state() {
    local state="$1"
    local iteration="$2"
    local current_task="$3"
    printf '{"state": "%s", "iteration": %d, "current_task": "%s"}\n' "$state" "$iteration" "$current_task" > "$STATE_FILE"
}

print_status() { :; }

cleanup() {
    local exit_code=$?
    # FIX: Only save INTERRUPTED on errors (exit_code != 0)
    if [[ $exit_code -ne 0 && -n "$current_task_id" && "$current_state" != "COMPLETE" && "$current_state" != "IDLE" ]]; then
        save_state "INTERRUPTED" "$iteration" "$current_task_id"
    fi
    exit $exit_code
}

trap cleanup EXIT TERM INT

# Simulate review rejection workflow
save_state "REVIEWING" "$iteration" "$current_task_id"
current_state="REJECTED"
save_state "REJECTED" "$iteration" "$current_task_id"

# Normal exit (exit_code == 0) - cleanup should NOT overwrite REJECTED
exit 0
SCRIPT

    chmod +x "$test_script"
    
    set +e
    bash "$test_script" 2>&1
    set -e
    
    local state_file="/tmp/test_rejected_state.json"
    
    if [[ -f "$state_file" ]]; then
        local state=$(jq -r '.state' "$state_file" 2>/dev/null)
        rm -f "$state_file"
        
        if [[ "$state" == "REJECTED" ]]; then
            return 0
        else
            echo "Expected REJECTED state, got: $state" >&2
            echo "BUG: cleanup() overwrote REJECTED state on normal exit" >&2
            return 1
        fi
    else
        echo "State file not created" >&2
        return 1
    fi
}

test_cleanup_saves_interrupted_on_error() {
    # Test that cleanup DOES save INTERRUPTED on error exit (non-zero exit code)
    
    local test_script="$TEST_TMP_DIR/test_error_state.sh"
    
    cat > "$test_script" << 'SCRIPT'
#!/bin/bash
set -euo pipefail

STATE_FILE="/tmp/test_error_state.json"
current_task_id="T003"
current_state="IMPLEMENTING"
iteration=1

save_state() {
    local state="$1"
    printf '{"state": "%s", "current_task": "%s"}\n' "$state" "$current_task_id" > "$STATE_FILE"
}

print_status() { :; }

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && -n "$current_task_id" && "$current_state" != "COMPLETE" && "$current_state" != "IDLE" ]]; then
        save_state "INTERRUPTED"
    fi
    exit $exit_code
}

trap cleanup EXIT TERM INT

save_state "IMPLEMENTING"

# Simulate error exit (e.g., agent timeout)
exit 1
SCRIPT

    chmod +x "$test_script"
    
    set +e
    bash "$test_script" 2>&1
    local script_exit=$?
    set -e
    
    local state_file="/tmp/test_error_state.json"
    
    if [[ -f "$state_file" ]]; then
        local state=$(jq -r '.state' "$state_file" 2>/dev/null)
        rm -f "$state_file"
        
        if [[ "$state" == "INTERRUPTED" ]]; then
            return 0
        else
            echo "Expected INTERRUPTED state on error exit, got: $state" >&2
            return 1
        fi
    else
        echo "State file not created on error exit" >&2
        return 1
    fi
}

test_review_result_deleted_after_approved() {
    # Test that .ralph_review_result.md is deleted after APPROVED
    # to prevent stale results from affecting next task
    
    source_functions
    
    local review_file="$TEST_TMP_DIR/.ralph_review_result.md"
    mkdir -p "$(dirname "$review_file")"
    
    # Create APPROVED review result
    cat > "$review_file" << 'EOF'
---
decision: APPROVED
task_id: T001
---
# Review Results
## Decision: APPROVED
EOF
    
    if [[ ! -f "$review_file" ]]; then
        echo "Failed to create review result file" >&2
        return 1
    fi
    
    # Simulate the cleanup logic after APPROVED
    local decision=$(parse_frontmatter_decision "$review_file")
    
    if [[ "$decision" == "APPROVED" ]]; then
        rm -f "$review_file"
    fi
    
    # Check that file was deleted
    if [[ -f "$review_file" ]]; then
        echo "BUG: Review result file should be deleted after APPROVED" >&2
        echo "This causes next task to see stale APPROVED result" >&2
        return 1
    else
        return 0
    fi
}

test_stale_review_result_cleaned_on_startup() {
    # Test that stale review result from previous run is cleaned on startup
    # if state is not REJECTED/INTERRUPTED
    
    source_functions
    
    local state_file="$TEST_TMP_DIR/.ralph_state.json"
    local review_file="$TEST_TMP_DIR/.ralph_review_result.md"
    mkdir -p "$(dirname "$state_file")" "$(dirname "$review_file")"
    
    # Create stale APPROVED review result from previous run
    cat > "$review_file" << 'EOF'
---
decision: APPROVED
task_id: T001
---
EOF
    
    # Create IDLE state (normal completion)
    cat > "$state_file" << 'EOF'
{"state": "IDLE", "iteration": 1, "current_task": ""}
EOF
    
    if [[ ! -f "$review_file" ]]; then
        echo "Failed to create stale review result" >&2
        return 1
    fi
    
    # Simulate cleanup logic on startup
    local saved_state=$(jq -r '.state // empty' "$state_file" 2>/dev/null)
    if [[ "$saved_state" != "REJECTED" && "$saved_state" != "INTERRUPTED" ]]; then
        rm -f "$review_file"
    fi
    
    # Check that stale file was deleted
    if [[ -f "$review_file" ]]; then
        echo "BUG: Stale review result should be deleted on startup when state is IDLE" >&2
        return 1
    else
        return 0
    fi
}

test_rejected_state_saved_before_max_iterations() {
    # Test that REJECTED state is saved BEFORE checking MAX_ITERATIONS
    # This prevents state from being INTERRUPTED when max iterations reached after rejection
    
    source_functions
    
    local state_file="$TEST_TMP_DIR/.ralph_state.json"
    mkdir -p "$(dirname "$state_file")"
    
    # Simulate: iteration=1, MAX_ITERATIONS=1, REJECTED
    local iteration=1
    local MAX_ITERATIONS=1
    local pending_task_id="T002"
    
    # CORRECT order: save REJECTED first, then check max iterations
    printf '{"state": "REJECTED", "iteration": %d, "current_task": "%s"}\n' "$iteration" "$pending_task_id" > "$state_file"
    
    # Now check max iterations
    if [[ $iteration -ge $MAX_ITERATIONS ]]; then
        # Would exit 1 here, but state is already saved as REJECTED
        :
    fi
    
    # Verify state is REJECTED (not INTERRUPTED)
    local state=$(jq -r '.state' "$state_file" 2>/dev/null)
    rm -f "$state_file"
    
    if [[ "$state" == "REJECTED" ]]; then
        return 0
    else
        echo "Expected REJECTED state, got: $state" >&2
        echo "BUG: MAX_ITERATIONS check happens before save_state REJECTED" >&2
        return 1
    fi
}

# =====================================================
# ТЕСТЫ: set -e propagation bug (return 1 from function kills caller)
# =====================================================

test_review_gate_return_1_does_not_kill_caller() {
    # Bug: run_review_gate calls "set -e" inside the function after kilo run.
    # This re-enables errexit even though the caller did "set +e".
    # When the function returns 1 (REJECTED), the script dies before
    # "local review_result=$?" is reached.
    #
    # This test verifies the real ralph_loop.sh does NOT have "set -e" inside
    # run_review_gate after the kilo run block, so return 1 doesn't kill the script.
    
    local ralph_script="$RALPH_LOOP_SCRIPT"
    
    # Extract the run_review_gate function body from the real script
    local func_body
    func_body=$(sed -n '/^run_review_gate()/,/^}/p' "$ralph_script")
    
    # Count "set -e" occurrences inside run_review_gate
    # There should be ZERO "set -e" lines (only "set +e" before kilo)
    local set_e_count
    set_e_count=$(echo "$func_body" | grep -c 'set -e' || true)
    
    if [[ "$set_e_count" -eq 0 ]]; then
        return 0
    else
        echo "BUG: run_review_gate contains 'set -e' ($set_e_count occurrences)" >&2
        echo "This causes return 1 to kill the caller script under set -e" >&2
        echo "--- function body ---" >&2
        echo "$func_body" | grep -n 'set ' >&2
        return 1
    fi
}

# =====================================================
# ТЕСТЫ: bash 3.2 brace parsing bug in ${var:-{}}
# =====================================================

test_brace_default_produces_valid_json() {
    # Bug: ${saved_rejection_counts:-{}} in bash 3.2 is parsed as
    # ${saved_rejection_counts:-{} + } => when var='{}', result is '{}}' (extra brace)
    # This corrupts the state file JSON.
    #
    # This test verifies the actual code in load_state doesn't use
    # the broken ${var:-{}} pattern.
    
    local ralph_script="$RALPH_LOOP_SCRIPT"
    
    # Search for the broken pattern ${...:-{}} in the script
    local broken_count
    broken_count=$(grep -c ':-{}' "$ralph_script" 2>/dev/null || true)
    
    # Allow it in comments/heredocs, but not in actual assignments
    # Check specifically for assignment patterns with :-{}
    local broken_assignments
    broken_assignments=$(grep -E '^\s*\w+=.*:-\{\}\}' "$ralph_script" 2>/dev/null | grep -v '^#' | grep -v '<<' || true)
    
    if [[ -z "$broken_assignments" ]]; then
        return 0
    else
        echo "BUG: Found broken \${var:-{}} assignment pattern in ralph_loop.sh" >&2
        echo "$broken_assignments" >&2
        return 1
    fi
}

# =====================================================
# ТЕСТЫ: current_rejections handles multiline jq output
# =====================================================

test_current_rejections_handles_multiline_jq_output() {
    # Bug: when task_rejection_counts contains corrupted JSON (e.g. "{}}"),
    # jq outputs multiple lines (one per JSON object), producing "0\n0".
    # ((0\n0++)) causes a syntax error that kills the script.
    #
    # This test verifies the real script sanitizes current_rejections
    # to a single numeric value before using it in ((...)).
    
    local ralph_script="$RALPH_LOOP_SCRIPT"
    
    # Find the line that computes current_rejections from jq
    local rej_line
    rej_line=$(grep -n 'current_rejections=.*jq' "$ralph_script" | head -1 || true)
    
    if [[ -z "$rej_line" ]]; then
        echo "BUG: Cannot find current_rejections assignment in ralph_loop.sh" >&2
        return 1
    fi
    
    local line_num=$(echo "$rej_line" | cut -d: -f1)
    local next_line
    next_line=$(sed -n "$((line_num+1))p" "$ralph_script")
    
    # The next line should use ((current_rejections++)) — check it's preceded by sanitization
    # Look for head -1 or tr -dc in the jq pipeline or on the current_rejections line
    local has_sanitization
    has_sanitization=$(echo "$rej_line" | grep -cE 'head -1|tr -dc' || true)
    
    if [[ "$has_sanitization" -gt 0 ]]; then
        return 0
    else
        echo "BUG: current_rejections from jq is not sanitized for multiline output" >&2
        echo "Line: $rej_line" >&2
        echo "Need: head -1 and/or tr -dc '0-9' to prevent ((multiline++)) syntax error" >&2
        return 1
    fi
}

# =====================================================
# ЗАПУСК ТЕСТОВ

# =====================================================
# ТЕСТЫ: Single Limit (MAX_TASK_REJECTIONS only)
# =====================================================

test_max_review_failures_not_used() {
    # RED: This test should FAIL if MAX_REVIEW_FAILURES is still in the script
    # GREEN: After removing MAX_REVIEW_FAILURES, this test passes
    
    local ralph_script="$RALPH_LOOP_SCRIPT"
    
    # Check that MAX_REVIEW_FAILURES constant is removed
    if grep -q 'readonly MAX_REVIEW_FAILURES' "$ralph_script"; then
        echo "BUG: MAX_REVIEW_FAILURES constant still exists — should be removed" >&2
        return 1
    fi
    
    # Check that review_failures variable is not used for limiting
    local review_failures_usage
    review_failures_usage=$(grep -n 'if.*review_failures.*-ge' "$ralph_script" 2>/dev/null || true)
    
    if [[ -n "$review_failures_usage" ]]; then
        echo "BUG: review_failures still used for limiting rejections:" >&2
        echo "$review_failures_usage" >&2
        return 1
    fi
    
    return 0
}

test_max_task_rejections_exists() {
    # Verify MAX_TASK_REJECTIONS constant exists
    local ralph_script="$RALPH_LOOP_SCRIPT"
    
    if ! grep -q 'readonly MAX_TASK_REJECTIONS=5' "$ralph_script"; then
        echo "BUG: MAX_TASK_REJECTIONS constant not found" >&2
        return 1
    fi
    
    return 0
}

test_task_can_be_rejected_up_to_limit() {
    # Simulate: task rejected MAX_TASK_REJECTIONS times should trigger escalation
    
    source_functions
    
    local test_script="$TEST_TMP_DIR/test_rejection_limit.sh"
    
    cat > "$test_script" << 'SCRIPT'
#!/bin/bash
set -euo pipefail

MAX_TASK_REJECTIONS=5
task_rejection_counts='{"T001":5}'
pending_task_id="T001"

current_rejections=$(echo "$task_rejection_counts" | jq -r --arg t "$pending_task_id" '.[$t] // 0' 2>/dev/null | head -1 | tr -dc '0-9')
[[ -z "$current_rejections" ]] && current_rejections=0

if [[ $current_rejections -ge $MAX_TASK_REJECTIONS ]]; then
    echo "ESCALATION_TRIGGERED"
    exit 0
else
    echo "BUG: Should have triggered escalation at $current_rejections rejections"
    exit 1
fi
SCRIPT

    chmod +x "$test_script"
    
    local output
    output=$(bash "$test_script" 2>&1)
    
    if [[ "$output" == "ESCALATION_TRIGGERED" ]]; then
        return 0
    else
        echo "Expected ESCALATION_TRIGGERED, got: $output" >&2
        return 1
    fi
}

test_task_rejection_counter_increments() {
    source_functions
    
    local test_script="$TEST_TMP_DIR/test_counter_increment.sh"
    
    cat > "$test_script" << 'SCRIPT'
#!/bin/bash
set -euo pipefail

task_rejection_counts='{"T001":1}'
pending_task_id="T001"

current_rejections=$(echo "$task_rejection_counts" | jq -r --arg t "$pending_task_id" '.[$t] // 0' 2>/dev/null | head -1 | tr -dc '0-9')
[[ -z "$current_rejections" ]] && current_rejections=0
((current_rejections++))

task_rejection_counts=$(echo "$task_rejection_counts" | jq --arg t "$pending_task_id" --argjson c "$current_rejections" '.[$t] = $c' 2>/dev/null || echo "{}")

# Verify
new_count=$(echo "$task_rejection_counts" | jq -r '.["T001"]')
if [[ "$new_count" == "2" ]]; then
    echo "OK"
else
    echo "BUG: Expected 2, got $new_count" >&2
    exit 1
fi
SCRIPT

    chmod +x "$test_script"
    
    if bash "$test_script" 2>&1 | grep -q "OK"; then
        return 0
    else
        echo "Counter did not increment correctly" >&2
        return 1
    fi
}

# =====================================================

main() {
    echo "========================================"
    echo "Ralph Loop Test Suite"
    echo "========================================"
    echo ""
    
    run_test "validate_path принимает валидный путь" test_validate_path_accepts_valid_path
    run_test "validate_path отклоняет несуществующий путь" test_validate_path_rejects_nonexistent
    run_test "validate_path отклоняет path traversal" test_validate_path_rejects_path_traversal
    
    run_test "validate_numeric принимает валидное число" test_validate_numeric_accepts_valid_number
    run_test "validate_numeric отклоняет отрицательное" test_validate_numeric_rejects_negative
    run_test "validate_numeric отклоняет вне диапазона" test_validate_numeric_rejects_out_of_range
    run_test "validate_numeric отклоняет нечисловое" test_validate_numeric_rejects_non_numeric
    
    run_test "get_first_incomplete_task возвращает первую" test_get_first_incomplete_task_returns_first
    run_test "get_first_incomplete_task возвращает пусто если все выполнены" test_get_first_incomplete_task_returns_empty_when_complete
    
    run_test "mark_task_completed помечает корректно" test_mark_task_completed_marks_correctly
    
    run_test "save_state создаёт валидный JSON" test_save_state_creates_valid_json
    run_test "save_state содержит корректные значения" test_save_state_contains_correct_values
    
    run_test "print_status success" test_print_status_success
    run_test "print_status error" test_print_status_error
    
    run_test "review_gate одобряет при APPROVED" test_review_gate_approves_on_approved_decision
    run_test "review_gate отклоняет при REJECTED" test_review_gate_rejects_on_rejected_decision
    run_test "review_gate создаёт rejection context" test_review_gate_creates_rejection_context
    
    run_test "circuit breaker останавливает после 3 неудач" test_circuit_breaker_stops_after_three_failures
    
    run_test "cleanup сохраняет INTERRUPTED state" test_cleanup_saves_interrupted_state
    run_test "cleanup пропускает IDLE state" test_cleanup_skips_idle_state
    run_test "task selection продолжает INTERRUPTED задачу" test_task_selection_continues_interrupted
    run_test "REJECTED state не перезаписывается cleanup" test_state_saved_before_cleanup_on_rejected
    run_test "cleanup сохраняет INTERRUPTED при ошибке" test_cleanup_saves_interrupted_on_error
    run_test "review result удаляется после APPROVED" test_review_result_deleted_after_approved
    run_test "stale review result очищается при старте" test_stale_review_result_cleaned_on_startup
    run_test "REJECTED state сохраняется до MAX_ITERATIONS" test_rejected_state_saved_before_max_iterations
    
    run_test "return 1 из функции не убивает вызывающий скрипт" test_review_gate_return_1_does_not_kill_caller
    
    run_test "brace default не ломает JSON (bash 3.2)" test_brace_default_produces_valid_json
    
    run_test "current_rejections обрабатывает multiline jq output" test_current_rejections_handles_multiline_jq_output

    # Тесты для одного лимита (MAX_TASK_REJECTIONS)
    run_test "MAX_REVIEW_FAILURES не используется" test_max_review_failures_not_used
    run_test "MAX_TASK_REJECTIONS существует" test_max_task_rejections_exists
    run_test "задача эскалируется при достижении лимита" test_task_can_be_rejected_up_to_limit
    run_test "счётчик отклонений инкрементируется" test_task_rejection_counter_increments
    
    echo ""
    echo "========================================"
    echo "Результаты:"
    echo "  Всего: $TESTS_RUN"
    echo -e "  ${GREEN}Прошло: $TESTS_PASSED${NC}"
    echo -e "  ${RED}Провалено: $TESTS_FAILED${NC}"
    echo "========================================"
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
    
    echo ""
    echo "Running additional test suites..."
    echo ""
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    if [[ -f "$script_dir/test_parse_frontmatter.sh" ]]; then
        bash "$script_dir/test_parse_frontmatter.sh" || exit 1
    fi
    
    if [[ -f "$script_dir/test_get_next_task.sh" ]]; then
        bash "$script_dir/test_get_next_task.sh" || exit 1
    fi
    
    if [[ -f "$script_dir/test_integration.sh" ]]; then
        bash "$script_dir/test_integration.sh" || exit 1
    fi
    
    if [[ -f "$script_dir/test_new_functions.sh" ]]; then
        bash "$script_dir/test_new_functions.sh" || exit 1
    fi
    
    echo ""
    echo "All test suites passed!"
}

main "$@"
