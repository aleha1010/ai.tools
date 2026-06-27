#!/usr/bin/env bash
#
# Tests for task-generator functionality
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_LOOP_DIR="$(dirname "$SCRIPT_DIR")"

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
    
    mkdir -p features/001-auth
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

extract_tasks_from_plan() {
    local plan_file="$1"
    local tasks_dir="$2"
    local tasks_file="$3"
    
    grep -E '^###\s+[A-Z0-9-]+:' "$plan_file" | while IFS= read -r line; do
        local task_id=$(echo "$line" | grep -oE '[A-Z]+-[0-9]+|T[0-9]+')
        local task_title=$(echo "$line" | sed -E 's/### [A-Z0-9-]+: //')
        echo "- [ ] ${task_id}: ${task_title}"
    done > "$tasks_file"
}

# =====================================================
# TESTS
# =====================================================

test_extract_tasks_creates_tasks_file() {
    cat > features/001-auth/plan.md << 'EOF'
# Plan

## Architecture

### T001: First task
Description here

### T002: Second task
Description here
EOF
    
    local tasks_file="features/001-auth/tasks.md"
    
    extract_tasks_from_plan "features/001-auth/plan.md" "features/001-auth/tasks" "$tasks_file"
    
    if [[ -f "$tasks_file" ]]; then
        return 0
    else
        echo "tasks.md should be created" >&2
        return 1
    fi
}

test_extract_tasks_correct_format() {
    cat > features/001-auth/plan.md << 'EOF'
# Plan

### T001: First task
Description

### T002: Second task
EOF
    
    local tasks_file="features/001-auth/tasks.md"
    
    extract_tasks_from_plan "features/001-auth/plan.md" "features/001-auth/tasks" "$tasks_file"
    
    if grep -q "\- \[ \] T001: First task" "$tasks_file" && grep -q "\- \[ \] T002: Second task" "$tasks_file"; then
        return 0
    else
        echo "Mixed ID formats should be supported" >&2
        cat "$tasks_file" >&2
        return 1
    fi
}

test_extract_tasks_preserves_order() {
    cat > features/001-auth/plan.md << 'EOF'
### T003: Third task
### T001: First task
### T002: Second task
EOF
    
    local tasks_file="features/001-auth/tasks.md"
    
    extract_tasks_from_plan "features/001-auth/plan.md" "features/001-auth/tasks" "$tasks_file"
    
    local first_task=$(head -1 "$tasks_file")
    local second_task=$(head -2 "$tasks_file" | tail -1)
    
    if [[ "$first_task" == *"T003"* ]] && [[ "$second_task" == *"T001"* ]]; then
        return 0
    else
        echo "Order should be preserved" >&2
        cat "$tasks_file" >&2
        return 1
    fi
}

test_extract_tasks_supports_mixed_ids() {
    cat > features/001-auth/plan.md << 'EOF'
### AUTH-001: Setup authentication
Description

### FIX-042: Fix login bug
Description

### HOTFIX-007: Critical patch
Description

### T001: Regular task
Description
EOF
    
    local tasks_file="features/001-auth/tasks.md"
    
    extract_tasks_from_plan "features/001-auth/plan.md" "features/001-auth/tasks" "$tasks_file"
    
    if grep -q "AUTH-001: Setup authentication" "$tasks_file" && \
       grep -q "FIX-042: Fix login bug" "$tasks_file" && \
       grep -q "HOTFIX-007: Critical patch" "$tasks_file" && \
       grep -q "T001: Regular task" "$tasks_file"; then
        return 0
    else
        echo "Order should be preserved" >&2
        cat "$tasks_file" >&2
        return 1
    fi
}

# =====================================================
# MAIN
# =====================================================

main() {
    echo "========================================"
    echo "Tests: task-generator"
    echo "========================================"
    echo ""
    
    run_test "extract_tasks creates tasks.md" test_extract_tasks_creates_tasks_file
    run_test "extract_tasks correct format" test_extract_tasks_correct_format
    run_test "extract_tasks preserves order" test_extract_tasks_preserves_order
    run_test "extract_tasks supports mixed IDs" test_extract_tasks_supports_mixed_ids
    
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
