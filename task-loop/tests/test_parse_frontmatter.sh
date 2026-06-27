#!/usr/bin/env bash
#
# Tests for parse_frontmatter(), build_task_status_cache(), check_dependencies()
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
    
    mkdir -p features/001-auth/tasks
    
    cat > features/001-auth/tasks.md << 'EOF'
# Tasks

- [x] T000: Setup task
- [ ] T001: First task
- [ ] T002: Second task depends on T001
- [ ] T003: Third task
EOF
    
    TASKS_FILE="$TEST_TMP_DIR/features/001-auth/tasks.md"
    TASKS_DIR="$TEST_TMP_DIR/features/001-auth/tasks"
    STATE_FILE="$TEST_TMP_DIR/.task_loop_state.json"
    
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

# =====================================================
# TESTS: parse_frontmatter_cached()
# =====================================================

test_parse_frontmatter_valid_frontmatter() {
    cat > "$TASKS_DIR/T001.md" << 'EOF'
---
id: T001
dependencies: [T000]
---
# T001: First task
EOF
    
    local cache_file="$TEST_TMP_DIR/.frontmatter_cache"
    local result
    result=$(parse_frontmatter_cached "$TASKS_DIR/T001.md" "$cache_file")
    
    if [[ "$result" == "T000" ]]; then
        return 0
    else
        echo "Expected 'T000', got '$result'" >&2
        return 1
    fi
}

test_parse_frontmatter_empty_dependencies() {
    cat > "$TASKS_DIR/T001.md" << 'EOF'
---
id: T001
dependencies: []
---
# T001: First task
EOF
    
    local cache_file="$TEST_TMP_DIR/.frontmatter_cache"
    local result
    result=$(parse_frontmatter_cached "$TASKS_DIR/T001.md" "$cache_file")
    
    if [[ -z "$result" ]]; then
        return 0
    else
        echo "Expected empty, got '$result'" >&2
        return 1
    fi
}

test_parse_frontmatter_missing_frontmatter() {
    cat > "$TASKS_DIR/T001.md" << 'EOF'
# T001: Task without frontmatter
EOF
    
    local cache_file="$TEST_TMP_DIR/.frontmatter_cache"
    local result
    result=$(parse_frontmatter_cached "$TASKS_DIR/T001.md" "$cache_file")
    
    if [[ -z "$result" ]]; then
        return 0
    else
        echo "Expected empty for missing frontmatter, got '$result'" >&2
        return 1
    fi
}

test_parse_frontmatter_invalid_yaml() {
    cat > "$TASKS_DIR/T001.md" << 'EOF'
---
id: T001
dependencies: [broken
---
# T001: Task with broken YAML
EOF
    
    local cache_file="$TEST_TMP_DIR/.frontmatter_cache"
    local result
    result=$(parse_frontmatter_cached "$TASKS_DIR/T001.md" "$cache_file")
    
    if [[ -z "$result" ]]; then
        return 0
    else
        echo "Expected empty for invalid YAML, got '$result'" >&2
        return 1
    fi
}

test_parse_frontmatter_multiple_dependencies() {
    cat > "$TASKS_DIR/T002.md" << 'EOF'
---
id: T002
dependencies: [T000, T001]
---
# T002: Task with multiple dependencies
EOF
    
    local cache_file="$TEST_TMP_DIR/.frontmatter_cache"
    local result
    result=$(parse_frontmatter_cached "$TASKS_DIR/T002.md" "$cache_file")
    
    if [[ "$result" == *"T000"* && "$result" == *"T001"* ]]; then
        return 0
    else
        echo "Expected 'T000' and 'T001', got '$result'" >&2
        return 1
    fi
}

test_parse_frontmatter_uses_cache() {
    cat > "$TASKS_DIR/T001.md" << 'EOF'
---
id: T001
dependencies: [T000]
---
# T001: First task
EOF
    
    local cache_file="$TEST_TMP_DIR/.frontmatter_cache"
    parse_frontmatter_cached "$TASKS_DIR/T001.md" "$cache_file" > /dev/null
    
    rm "$TASKS_DIR/T001.md"
    
    local result
    result=$(parse_frontmatter_cached "$TASKS_DIR/T001.md" "$cache_file")
    
    if [[ "$result" == "T000" ]]; then
        return 0
    else
        echo "Expected cached value 'T000', got '$result'" >&2
        return 1
    fi
}

test_parse_frontmatter_whitelist_validation() {
    cat > "$TASKS_DIR/T001.md" << 'EOF'
---
id: T001
dependencies: [T000, MALICIOUS, T002]
---
# T001: Task with invalid dependency ID
EOF
    
    local cache_file="$TEST_TMP_DIR/.frontmatter_cache"
    local result
    result=$(parse_frontmatter_cached "$TASKS_DIR/T001.md" "$cache_file")
    
    if [[ "$result" == *"T000"* && "$result" == *"T002"* && "$result" != *"MALICIOUS"* ]]; then
        return 0
    else
        echo "Expected only valid T### IDs, got '$result'" >&2
        return 1
    fi
}

# =====================================================
# TESTS: build_task_status_cache()
# =====================================================

test_build_cache_correct_status() {
    local cache_file="$TEST_TMP_DIR/.status_cache"
    build_task_status_cache "$TASKS_FILE" "$cache_file"
    
    local t000_status
    t000_status=$(get_task_status "T000" "$cache_file")
    local t001_status
    t001_status=$(get_task_status "T001" "$cache_file")
    
    if [[ "$t000_status" == "x" && "$t001_status" == " " ]]; then
        return 0
    else
        echo "Cache: T000=$t000_status, T001=$t001_status" >&2
        return 1
    fi
}

test_build_cache_all_tasks_present() {
    local cache_file="$TEST_TMP_DIR/.status_cache"
    build_task_status_cache "$TASKS_FILE" "$cache_file"
    
    local t000 t001 t002 t003
    t000=$(get_task_status "T000" "$cache_file")
    t001=$(get_task_status "T001" "$cache_file")
    t002=$(get_task_status "T002" "$cache_file")
    t003=$(get_task_status "T003" "$cache_file")
    
    if [[ -n "$t000" && -n "$t001" && -n "$t002" && -n "$t003" ]]; then
        return 0
    else
        echo "Not all tasks in cache" >&2
        return 1
    fi
}

# =====================================================
# TESTS: check_dependencies()
# =====================================================

test_check_dependencies_all_completed() {
    cat > "$TASKS_DIR/T001.md" << 'EOF'
---
id: T001
dependencies: [T000]
---
# T001: Depends on T000
EOF
    
    local status_cache="$TEST_TMP_DIR/.status_cache"
    local frontmatter_cache="$TEST_TMP_DIR/.frontmatter_cache"
    
    build_task_status_cache "$TASKS_FILE" "$status_cache"
    
    if check_dependencies "$TASKS_DIR/T001.md" "$status_cache" "$frontmatter_cache"; then
        return 0
    else
        echo "Dependencies should be satisfied (T000 is completed)" >&2
        return 1
    fi
}

test_check_dependencies_incomplete_dependency() {
    cat > "$TASKS_DIR/T002.md" << 'EOF'
---
id: T002
dependencies: [T001]
---
# T002: Depends on incomplete T001
EOF
    
    local status_cache="$TEST_TMP_DIR/.status_cache"
    local frontmatter_cache="$TEST_TMP_DIR/.frontmatter_cache"
    
    build_task_status_cache "$TASKS_FILE" "$status_cache"
    
    if check_dependencies "$TASKS_DIR/T002.md" "$status_cache" "$frontmatter_cache"; then
        echo "Should fail when dependency is incomplete" >&2
        return 1
    else
        return 0
    fi
}

test_check_dependencies_no_dependencies() {
    cat > "$TASKS_DIR/T001.md" << 'EOF'
---
id: T001
dependencies: []
---
# T001: No dependencies
EOF
    
    local status_cache="$TEST_TMP_DIR/.status_cache"
    local frontmatter_cache="$TEST_TMP_DIR/.frontmatter_cache"
    
    build_task_status_cache "$TASKS_FILE" "$status_cache"
    
    if check_dependencies "$TASKS_DIR/T001.md" "$status_cache" "$frontmatter_cache"; then
        return 0
    else
        echo "Should pass when no dependencies" >&2
        return 1
    fi
}

test_check_dependencies_missing_frontmatter() {
    cat > "$TASKS_DIR/T001.md" << 'EOF'
# T001: No frontmatter
EOF
    
    local status_cache="$TEST_TMP_DIR/.status_cache"
    local frontmatter_cache="$TEST_TMP_DIR/.frontmatter_cache"
    
    build_task_status_cache "$TASKS_FILE" "$status_cache"
    
    if check_dependencies "$TASKS_DIR/T001.md" "$status_cache" "$frontmatter_cache"; then
        return 0
    else
        echo "Should pass when frontmatter missing (no dependencies)" >&2
        return 1
    fi
}

test_check_dependencies_multiple_deps_partial() {
    cat > "$TASKS_DIR/T002.md" << 'EOF'
---
id: T002
dependencies: [T000, T001]
---
# T002: Depends on T000 (done) and T001 (incomplete)
EOF
    
    local status_cache="$TEST_TMP_DIR/.status_cache"
    local frontmatter_cache="$TEST_TMP_DIR/.frontmatter_cache"
    
    build_task_status_cache "$TASKS_FILE" "$status_cache"
    
    if check_dependencies "$TASKS_DIR/T002.md" "$status_cache" "$frontmatter_cache"; then
        echo "Should fail when one dependency incomplete" >&2
        return 1
    else
        return 0
    fi
}

# =====================================================
# TESTS: validate_tasks_integrity()
# =====================================================

test_validate_integrity_all_files_exist() {
    for task_id in T001 T002 T003; do
        echo "# $task_id" > "$TASKS_DIR/${task_id}.md"
    done
    
    if validate_tasks_integrity "$TASKS_FILE" "$TASKS_DIR" 2>&1; then
        return 0
    else
        echo "Should pass when all task files exist" >&2
        return 1
    fi
}

test_validate_integrity_missing_file() {
    echo "# T001" > "$TASKS_DIR/T001.md"
    
    if validate_tasks_integrity "$TASKS_FILE" "$TASKS_DIR" 2>&1; then
        echo "Should fail when task file missing" >&2
        return 1
    else
        return 0
    fi
}

# =====================================================
# MAIN
# =====================================================

main() {
    echo "========================================"
    echo "Tests: parse_frontmatter, dependencies"
    echo "========================================"
    echo ""
    
    run_test "parse_frontmatter valid frontmatter" test_parse_frontmatter_valid_frontmatter
    run_test "parse_frontmatter empty dependencies" test_parse_frontmatter_empty_dependencies
    run_test "parse_frontmatter missing frontmatter" test_parse_frontmatter_missing_frontmatter
    run_test "parse_frontmatter invalid YAML" test_parse_frontmatter_invalid_yaml
    run_test "parse_frontmatter multiple dependencies" test_parse_frontmatter_multiple_dependencies
    run_test "parse_frontmatter uses cache" test_parse_frontmatter_uses_cache
    run_test "parse_frontmatter whitelist validation" test_parse_frontmatter_whitelist_validation
    
    run_test "build_cache correct status" test_build_cache_correct_status
    run_test "build_cache all tasks present" test_build_cache_all_tasks_present
    
    run_test "check_dependencies all completed" test_check_dependencies_all_completed
    run_test "check_dependencies incomplete dependency" test_check_dependencies_incomplete_dependency
    run_test "check_dependencies no dependencies" test_check_dependencies_no_dependencies
    run_test "check_dependencies missing frontmatter" test_check_dependencies_missing_frontmatter
    run_test "check_dependencies multiple deps partial" test_check_dependencies_multiple_deps_partial
    
    run_test "validate_integrity all files exist" test_validate_integrity_all_files_exist
    run_test "validate_integrity missing file" test_validate_integrity_missing_file
    
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
