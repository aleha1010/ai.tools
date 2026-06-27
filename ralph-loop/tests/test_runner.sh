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
# ЗАПУСК ТЕСТОВ
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
