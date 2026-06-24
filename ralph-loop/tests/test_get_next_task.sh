#!/usr/bin/env bash
#
# Tests for get_next_executable_task()
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_LOOP_DIR="$(dirname "$SCRIPT_DIR")"

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
    
    mkdir -p features/001-auth/tasks
    
    TASKS_FILE="$TEST_TMP_DIR/features/001-auth/tasks.md"
    TASKS_DIR="$TEST_TMP_DIR/features/001-auth/tasks"
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

get_next_executable_task() {
    local tasks_file="$1"
    local tasks_dir="$2"
    local status_cache="$3"
    
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^\s*-\s*\[ \]\s+T[0-9]+'; then
            local task_id=$(echo "$line" | grep -oE 'T[0-9]+' | head -1)
            local task_file="$tasks_dir/${task_id}.md"
            local frontmatter_cache="/tmp/.frontmatter_${task_id}_$$"
            
            if [[ ! -f "$task_file" ]]; then
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

# =====================================================
# TESTS
# =====================================================

test_get_next_task_no_dependencies() {
    cat > "$TASKS_FILE" << 'EOF'
- [ ] T001: First task
- [ ] T002: Second task
EOF
    
    cat > "$TASKS_DIR/T001.md" << 'EOF'
---
id: T001
dependencies: []
---
# T001
EOF
    
    cat > "$TASKS_DIR/T002.md" << 'EOF'
---
id: T002
dependencies: []
---
# T002
EOF
    
    local cache_file="$TEST_TMP_DIR/.status_cache"
    build_task_status_cache "$TASKS_FILE" "$cache_file"
    
    local result
    result=$(get_next_executable_task "$TASKS_FILE" "$TASKS_DIR" "$cache_file")
    
    if [[ "$result" == "T001" ]]; then
        return 0
    else
        echo "Expected T001, got '$result'" >&2
        return 1
    fi
}

test_get_next_task_with_satisfied_deps() {
    cat > "$TASKS_FILE" << 'EOF'
- [x] T000: Setup
- [ ] T001: Depends on T000
- [ ] T002: No deps
EOF
    
    cat > "$TASKS_DIR/T001.md" << 'EOF'
---
id: T001
dependencies: [T000]
---
# T001
EOF
    
    cat > "$TASKS_DIR/T002.md" << 'EOF'
---
id: T002
dependencies: []
---
# T002
EOF
    
    local cache_file="$TEST_TMP_DIR/.status_cache"
    build_task_status_cache "$TASKS_FILE" "$cache_file"
    
    local result
    result=$(get_next_executable_task "$TASKS_FILE" "$TASKS_DIR" "$cache_file")
    
    if [[ "$result" == "T001" ]]; then
        return 0
    else
        echo "Expected T001 (deps satisfied), got '$result'" >&2
        return 1
    fi
}

test_get_next_task_skip_blocked() {
    cat > "$TASKS_FILE" << 'EOF'
- [ ] T001: Blocked by T000
- [ ] T002: Not blocked
EOF
    
    cat > "$TASKS_DIR/T001.md" << 'EOF'
---
id: T001
dependencies: [T000]
---
# T001
EOF
    
    cat > "$TASKS_DIR/T002.md" << 'EOF'
---
id: T002
dependencies: []
---
# T002
EOF
    
    local cache_file="$TEST_TMP_DIR/.status_cache"
    build_task_status_cache "$TASKS_FILE" "$cache_file"
    
    local result
    result=$(get_next_executable_task "$TASKS_FILE" "$TASKS_DIR" "$cache_file")
    
    if [[ "$result" == "T002" ]]; then
        return 0
    else
        echo "Expected T002 (T001 blocked), got '$result'" >&2
        return 1
    fi
}

test_get_next_task_all_blocked() {
    cat > "$TASKS_FILE" << 'EOF'
- [ ] T001: Blocked by T000
- [ ] T002: Blocked by T001
EOF
    
    cat > "$TASKS_DIR/T001.md" << 'EOF'
---
id: T001
dependencies: [T000]
---
# T001
EOF
    
    cat > "$TASKS_DIR/T002.md" << 'EOF'
---
id: T002
dependencies: [T001]
---
# T002
EOF
    
    local cache_file="$TEST_TMP_DIR/.status_cache"
    build_task_status_cache "$TASKS_FILE" "$cache_file"
    
    local result
    result=$(get_next_executable_task "$TASKS_FILE" "$TASKS_DIR" "$cache_file")
    
    if [[ -z "$result" ]]; then
        return 0
    else
        echo "Expected empty (all blocked), got '$result'" >&2
        return 1
    fi
}

test_get_next_task_missing_file() {
    cat > "$TASKS_FILE" << 'EOF'
- [ ] T001: Missing file
- [ ] T002: Exists
EOF
    
    cat > "$TASKS_DIR/T002.md" << 'EOF'
---
id: T002
dependencies: []
---
# T002
EOF
    
    local cache_file="$TEST_TMP_DIR/.status_cache"
    build_task_status_cache "$TASKS_FILE" "$cache_file"
    
    local result
    result=$(get_next_executable_task "$TASKS_FILE" "$TASKS_DIR" "$cache_file")
    
    if [[ "$result" == "T002" ]]; then
        return 0
    else
        echo "Expected T002 (T001 file missing), got '$result'" >&2
        return 1
    fi
}

# =====================================================
# MAIN
# =====================================================

main() {
    echo "========================================"
    echo "Tests: get_next_executable_task"
    echo "========================================"
    echo ""
    
    run_test "get_next_task no dependencies" test_get_next_task_no_dependencies
    run_test "get_next_task with satisfied deps" test_get_next_task_with_satisfied_deps
    run_test "get_next_task skip blocked" test_get_next_task_skip_blocked
    run_test "get_next_task all blocked" test_get_next_task_all_blocked
    run_test "get_next_task missing file" test_get_next_task_missing_file
    
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
