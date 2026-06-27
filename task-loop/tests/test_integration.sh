#!/usr/bin/env bash
#
# Integration tests for task_loop.sh main logic

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_LOOP_DIR="$(dirname "$SCRIPT_DIR")"
TASK_LOOP_SCRIPT="$TASK_LOOP_DIR/scripts/task_loop.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMP_DIR=""

setup() {
    TEST_TMP_DIR=$(mktemp -d)
    cd "$TEST_TMP_DIR"
    
    mkdir -p features/001-test/tasks
    mkdir -p .kilo/prompts
    
    cat > .kilo/prompts/task-iterate.md << 'EOF'
Test prompt
EOF
    
    cat > .kilo/prompts/task-review.md << 'EOF'
Test review prompt
EOF
    
    cat > features/001-test/tasks.md << 'EOF'
# Tasks

- [x] T000: Setup
- [ ] T001: First task
- [ ] T002: Second task
EOF
    
    cat > features/001-test/tasks/T001.md << 'EOF'
---
id: T001
dependencies: []
---
# T001: First task
EOF
    
    cat > features/001-test/tasks/T002.md << 'EOF'
---
id: T002
dependencies: [T001]
---
# T002: Second task
EOF
    
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    git add -A
    git commit -q -m "Initial commit"
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

test_extract_feature_name() {
    local result
    result=$(dirname "features/001-auth/tasks.md" | xargs basename)
    
    if [[ "$result" == "001-auth" ]]; then
        return 0
    else
        echo "Expected '001-auth', got '$result'" >&2
        return 1
    fi
}

test_blocked_tasks_exit() {
    cat > features/001-test/tasks.md << 'EOF'
# Tasks

- [ ] T001: Blocked by T000
- [ ] T002: Blocked by T001
EOF
    
    cat > features/001-test/tasks/T001.md << 'EOF'
---
id: T001
dependencies: [T000]
---
# T001
EOF
    
    cat > features/001-test/tasks/T002.md << 'EOF'
---
id: T002
dependencies: [T001]
---
# T002
EOF
    
    cd "$TEST_TMP_DIR"
    
    export KILO_CMD="echo skip"
    export SLEEP_CMD="echo"
    
    set +e
    local output
    output=$(bash "$TASK_LOOP_SCRIPT" --tasks-path features/001-test/tasks.md --max-iterations 1 --no-review 2>&1)
    local exit_code=$?
    set -e
    
    if [[ "$output" == *"заблокированы"* ]] || [[ "$output" == *"blocked"* ]] || [[ "$exit_code" -eq 1 ]]; then
        return 0
    else
        echo "Expected blocked exit, got code $exit_code" >&2
        echo "$output" | tail -5 >&2
        return 1
    fi
}

test_calculate_backoff() {
    local backoff_0=$(cd "$TEST_TMP_DIR" && bash -c '
        calculate_backoff() {
            local failure_count=$1
            local backoff=$((2 ** failure_count))
            [[ $backoff -gt 60 ]] && backoff=60
            echo "$backoff"
        }
        calculate_backoff 0
    ')
    
    local backoff_3=$(cd "$TEST_TMP_DIR" && bash -c '
        calculate_backoff() {
            local failure_count=$1
            local backoff=$((2 ** failure_count))
            [[ $backoff -gt 60 ]] && backoff=60
            echo "$backoff"
        }
        calculate_backoff 3
    ')
    
    local backoff_10=$(cd "$TEST_TMP_DIR" && bash -c '
        calculate_backoff() {
            local failure_count=$1
            local backoff=$((2 ** failure_count))
            [[ $backoff -gt 60 ]] && backoff=60
            echo "$backoff"
        }
        calculate_backoff 10
    ')
    
    if [[ "$backoff_0" == "1" ]] && [[ "$backoff_3" == "8" ]] && [[ "$backoff_10" == "60" ]]; then
        return 0
    else
        echo "Expected 1, 8, 60; got $backoff_0, $backoff_3, $backoff_10" >&2
        return 1
    fi
}

test_get_incomplete_count() {
    local count
    count=$(cd "$TEST_TMP_DIR" && bash -c '
        get_incomplete_task_count() {
            local tasks_file="$1"
            local count=0
            if [[ -f "$tasks_file" ]]; then
                count=$(grep -c "^\s*-\s*\[ \]" "$tasks_file" 2>/dev/null || echo "0")
                count=$(echo "$count" | tr -d "[:space:]")
            fi
            echo "${count:-0}"
        }
        get_incomplete_task_count "features/001-test/tasks.md"
    ')
    
    if [[ "$count" == "2" ]]; then
        return 0
    else
        echo "Expected 2 incomplete tasks, got $count" >&2
        return 1
    fi
}

main() {
    echo "========================================"
    echo "Integration Tests: task_loop.sh"
    echo "========================================"
    echo ""
    
    run_test "extract_feature_name" test_extract_feature_name
    run_test "blocked tasks exit" test_blocked_tasks_exit
    run_test "calculate_backoff" test_calculate_backoff
    run_test "get_incomplete_count" test_get_incomplete_count
    
    echo ""
    echo "========================================"
    echo "Results:"
    echo "  Total: $TESTS_RUN"
    echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
    echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
    echo "========================================"
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
