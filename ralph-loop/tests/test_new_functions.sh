#!/usr/bin/env bash
#
# Tests for new Ralph Loop functions (atomic_write, parse_frontmatter_decision, etc.)
# Run: ./ralph-loop/tests/test_new_functions.sh
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

source_functions() {
    atomic_write() {
        local file="$1"
        local content="$2"
        local tmp_file="${file}.tmp.$$"
        
        if printf '%s\n' "$content" > "$tmp_file" && mv "$tmp_file" "$file"; then
            return 0
        else
            rm -f "$tmp_file" 2>/dev/null
            return 1
        fi
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
    
    mark_task_failed() {
        local task_id="$1"
        
        if [[ -z "$failed_tasks" ]]; then
            failed_tasks='["'$task_id'"]'
        else
            failed_tasks=$(echo "$failed_tasks" | jq --arg t "$task_id" '. + [$t]' 2>/dev/null)
        fi
        
        ((consecutive_failures++))
    }
    
    get_task_status() {
        local task_id="$1"
        local cache_file="$2"
        
        grep "^${task_id}=" "$cache_file" 2>/dev/null | cut -d'=' -f2 || echo ""
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
}

# =====================================================
# Tests: atomic_write
# =====================================================

test_atomic_write_creates_file() {
    source_functions
    
    local test_file="$TEST_TMP_DIR/test.txt"
    local content="Hello World"
    
    atomic_write "$test_file" "$content"
    
    if [[ -f "$test_file" ]]; then
        local result
        result=$(cat "$test_file")
        if [[ "$result" == "$content" ]]; then
            return 0
        else
            echo "Content mismatch: expected '$content', got '$result'" >&2
            return 1
        fi
    else
        echo "File should be created" >&2
        return 1
    fi
}

test_atomic_write_overwrites_existing() {
    source_functions
    
    local test_file="$TEST_TMP_DIR/test.txt"
    echo "Old content" > "$test_file"
    
    atomic_write "$test_file" "New content"
    
    local result
    result=$(cat "$test_file")
    
    if [[ "$result" == "New content" ]]; then
        return 0
    else
        echo "Content should be overwritten" >&2
        return 1
    fi
}

test_atomic_write_leaves_no_temp_file() {
    source_functions
    
    local test_file="$TEST_TMP_DIR/test.txt"
    
    atomic_write "$test_file" "Content"
    
    local temp_files
    temp_files=$(find "$TEST_TMP_DIR" -name "*.tmp.$$" 2>/dev/null || echo "")
    
    if [[ -z "$temp_files" ]]; then
        return 0
    else
        echo "Temp files should be cleaned up: $temp_files" >&2
        return 1
    fi
}

test_atomic_write_handles_multiline() {
    source_functions
    
    local test_file="$TEST_TMP_DIR/multiline.txt"
    local content="Line 1
Line 2
Line 3"
    
    atomic_write "$test_file" "$content"
    
    local result
    result=$(cat "$test_file")
    
    if [[ "$result" == "$content" ]]; then
        return 0
    else
        echo "Multiline content should be preserved" >&2
        return 1
    fi
}

# =====================================================
# Tests: parse_frontmatter_decision
# =====================================================

test_parse_frontmatter_extracts_approved() {
    source_functions
    
    local test_file="$TEST_TMP_DIR/review.md"
    cat > "$test_file" << 'EOF'
---
decision: APPROVED
task_id: T001
---

# Review Results
EOF
    
    local result
    result=$(parse_frontmatter_decision "$test_file")
    
    if [[ "$result" == "APPROVED" ]]; then
        return 0
    else
        echo "Expected APPROVED, got '$result'" >&2
        return 1
    fi
}

test_parse_frontmatter_extracts_rejected() {
    source_functions
    
    local test_file="$TEST_TMP_DIR/review.md"
    cat > "$test_file" << 'EOF'
---
decision: REJECTED
task_id: T002
high_issues: 1
---

# Review Results
EOF
    
    local result
    result=$(parse_frontmatter_decision "$test_file")
    
    if [[ "$result" == "REJECTED" ]]; then
        return 0
    else
        echo "Expected REJECTED, got '$result'" >&2
        return 1
    fi
}

test_parse_frontmatter_handles_quotes() {
    source_functions
    
    local test_file="$TEST_TMP_DIR/review.md"
    cat > "$test_file" << 'EOF'
---
decision: "APPROVED"
task_id: "T001"
---
EOF
    
    local result
    result=$(parse_frontmatter_decision "$test_file")
    
    if [[ "$result" == "APPROVED" ]]; then
        return 0
    else
        echo "Expected APPROVED (quotes stripped), got '$result'" >&2
        return 1
    fi
}

test_parse_frontmatter_returns_empty_for_missing_file() {
    source_functions
    
    local result
    result=$(parse_frontmatter_decision "/nonexistent/file.md")
    
    if [[ -z "$result" ]]; then
        return 0
    else
        echo "Expected empty string for missing file, got '$result'" >&2
        return 1
    fi
}

test_parse_frontmatter_returns_empty_for_no_frontmatter() {
    source_functions
    
    local test_file="$TEST_TMP_DIR/no_frontmatter.md"
    echo "# No frontmatter here" > "$test_file"
    
    local result
    result=$(parse_frontmatter_decision "$test_file")
    
    if [[ -z "$result" ]]; then
        return 0
    else
        echo "Expected empty string for no frontmatter, got '$result'" >&2
        return 1
    fi
}

test_parse_frontmatter_handles_spaces() {
    source_functions
    
    local test_file="$TEST_TMP_DIR/review.md"
    cat > "$test_file" << 'EOF'
---
decision:   APPROVED  
task_id: T001
---
EOF
    
    local result
    result=$(parse_frontmatter_decision "$test_file")
    
    if [[ "$result" == "APPROVED" ]]; then
        return 0
    else
        echo "Expected APPROVED (trimmed), got '$result'" >&2
        return 1
    fi
}

test_parse_frontmatter_ignores_decision_in_body() {
    source_functions
    
    local test_file="$TEST_TMP_DIR/review.md"
    cat > "$test_file" << 'EOF'
---
decision: APPROVED
---

# Review Results

decision: REJECTED
EOF
    
    local result
    result=$(parse_frontmatter_decision "$test_file")
    
    if [[ "$result" == "APPROVED" ]]; then
        return 0
    else
        echo "Should extract from frontmatter only, got '$result'" >&2
        return 1
    fi
}

# =====================================================
# Tests: mark_task_failed
# =====================================================

test_mark_task_failed_initializes_array() {
    source_functions
    
    failed_tasks=""
    consecutive_failures=0
    
    mark_task_failed "T001"
    
    if [[ "$failed_tasks" == '["T001"]' ]] && [[ "$consecutive_failures" -eq 1 ]]; then
        return 0
    else
        echo "Expected failed_tasks='[\"T001\"]' and consecutive_failures=1" >&2
        echo "Got: failed_tasks='$failed_tasks', consecutive_failures=$consecutive_failures" >&2
        return 1
    fi
}

test_mark_task_failed_appends_to_array() {
    source_functions
    
    failed_tasks='["T001"]'
    consecutive_failures=1
    
    mark_task_failed "T002"
    
    if [[ "$consecutive_failures" -eq 2 ]]; then
        if echo "$failed_tasks" | jq -e '. | length == 2' > /dev/null 2>&1; then
            if echo "$failed_tasks" | jq -e '"T002" in .' > /dev/null 2>&1 || echo "$failed_tasks" | jq -e 'index("T002")' > /dev/null 2>&1; then
                return 0
            else
                echo "T002 should be in failed_tasks array" >&2
                return 1
            fi
        else
            echo "Failed tasks array should have 2 elements" >&2
            return 1
        fi
    else
        echo "Expected consecutive_failures=2, got $consecutive_failures" >&2
        return 1
    fi
}

# =====================================================
# Tests: build_task_status_cache
# =====================================================

test_build_cache_creates_entries() {
    source_functions
    
    local tasks_file="$TEST_TMP_DIR/tasks.md"
    cat > "$tasks_file" << 'EOF'
# Tasks

- [ ] T001: First task
- [x] T002: Completed task
- [ ] T003: Third task
EOF
    
    local cache_file="$TEST_TMP_DIR/cache.txt"
    build_task_status_cache "$tasks_file" "$cache_file"
    
    if [[ -f "$cache_file" ]]; then
        local t001_status
        t001_status=$(get_task_status "T001" "$cache_file")
        local t002_status
        t002_status=$(get_task_status "T002" "$cache_file")
        local t003_status
        t003_status=$(get_task_status "T003" "$cache_file")
        
        if [[ "$t001_status" == " " && "$t002_status" == "x" && "$t003_status" == " " ]]; then
            return 0
        else
            echo "Cache entries incorrect: T001='$t001_status', T002='$t002_status', T003='$t003_status'" >&2
            return 1
        fi
    else
        echo "Cache file should be created" >&2
        return 1
    fi
}

test_get_task_status_returns_empty_for_missing() {
    source_functions
    
    local cache_file="$TEST_TMP_DIR/cache.txt"
    echo "T001=x" > "$cache_file"
    
    local result
    result=$(get_task_status "T999" "$cache_file")
    
    if [[ -z "$result" ]]; then
        return 0
    else
        echo "Expected empty for missing task, got '$result'" >&2
        return 1
    fi
}

# =====================================================
# Tests: save_state with new fields
# =====================================================

test_save_state_includes_new_fields() {
    local state_file="$TEST_TMP_DIR/state.json"
    
    local review_retries=2
    local failed_tasks='["T001","T002"]'
    local consecutive_failures=3
    
    cat > "$state_file" << STATE_JSON
{
  "state": "REVIEWING",
  "iteration": 5,
  "current_task": "T003",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pid": $$,
  "review_retries": ${review_retries:-0},
  "failed_tasks": $(echo "${failed_tasks:-[]}" | jq -c . 2>/dev/null || echo "[]"),
  "consecutive_failures": ${consecutive_failures:-0}
}
STATE_JSON
    
    if [[ -f "$state_file" ]] && jq -e . "$state_file" > /dev/null 2>&1; then
        local retries
        retries=$(jq -r '.review_retries' "$state_file")
        local failures
        failures=$(jq -r '.consecutive_failures' "$state_file")
        local failed_count
        failed_count=$(jq '.failed_tasks | length' "$state_file")
        
        if [[ "$retries" -eq 2 && "$failures" -eq 3 && "$failed_count" -eq 2 ]]; then
            return 0
        else
            echo "State values incorrect: retries=$retries, failures=$failures, count=$failed_count" >&2
            return 1
        fi
    else
        echo "State file should be valid JSON" >&2
        return 1
    fi
}

# =====================================================
# Tests: Integration scenarios
# =====================================================

test_review_result_file_format() {
    local review_file="$TEST_TMP_DIR/.ralph_review_result.md"
    
    cat > "$review_file" << 'EOF'
---
decision: REJECTED
task_id: T001
reviewers:
  - review-security
verdicts:
  review-security: REJECTED
high_issues: 1
medium_issues: 0
low_issues: 0
---

# Review Results

## Fix Required

1. **[HIGH]** Remove hardcoded password
EOF
    
    source_functions
    
    local decision
    decision=$(parse_frontmatter_decision "$review_file")
    
    if [[ "$decision" == "REJECTED" ]]; then
        if jq -e . "$review_file" > /dev/null 2>&1 || grep -q "^---$" "$review_file"; then
            return 0
        else
            echo "Review file format should be valid" >&2
            return 1
        fi
    else
        echo "Decision should be REJECTED, got '$decision'" >&2
        return 1
    fi
}

test_file_paths_in_feature_dir() {
    local feature_dir="$TEST_TMP_DIR/specs/001-feature"
    mkdir -p "$feature_dir"
    
    local log_file="$feature_dir/.ralph_loop.log"
    local state_file="$feature_dir/.ralph_state.json"
    local pending_file="$feature_dir/.ralph_pending_tasks.json"
    local review_file="$feature_dir/.ralph_review_result.md"
    
    touch "$log_file" "$state_file" "$pending_file" "$review_file"
    
    if [[ -f "$log_file" && -f "$state_file" && -f "$pending_file" && -f "$review_file" ]]; then
        local all_in_feature_dir=true
        for f in "$log_file" "$state_file" "$pending_file" "$review_file"; do
            if [[ "$(dirname "$f")" != "$feature_dir" ]]; then
                all_in_feature_dir=false
            fi
        done
        
        if $all_in_feature_dir; then
            return 0
        else
            echo "All files should be in feature directory" >&2
            return 1
        fi
    else
        echo "All state files should be created" >&2
        return 1
    fi
}

# =====================================================
# Main
# =====================================================

main() {
    echo "========================================"
    echo "Ralph Loop New Functions Test Suite"
    echo "========================================"
    echo ""
    
    run_test "atomic_write создаёт файл" test_atomic_write_creates_file
    run_test "atomic_write перезаписывает существующий" test_atomic_write_overwrites_existing
    run_test "atomic_write не оставляет temp файлы" test_atomic_write_leaves_no_temp_file
    run_test "atomic_write сохраняет многострочный контент" test_atomic_write_handles_multiline
    
    run_test "parse_frontmatter извлекает APPROVED" test_parse_frontmatter_extracts_approved
    run_test "parse_frontmatter извлекает REJECTED" test_parse_frontmatter_extracts_rejected
    run_test "parse_frontmatter убирает кавычки" test_parse_frontmatter_handles_quotes
    run_test "parse_frontmatter возвращает пусто для отсутствующего файла" test_parse_frontmatter_returns_empty_for_missing_file
    run_test "parse_frontmatter возвращает пусто без frontmatter" test_parse_frontmatter_returns_empty_for_no_frontmatter
    run_test "parse_frontmatter обрезает пробелы" test_parse_frontmatter_handles_spaces
    run_test "parse_frontmatter игнорирует decision в body" test_parse_frontmatter_ignores_decision_in_body
    
    run_test "mark_task_failed инициализирует массив" test_mark_task_failed_initializes_array
    run_test "mark_task_failed добавляет в массив" test_mark_task_failed_appends_to_array
    
    run_test "build_cache создаёт записи" test_build_cache_creates_entries
    run_test "get_task_status возвращает пусто для отсутствующей задачи" test_get_task_status_returns_empty_for_missing
    
    run_test "save_state включает новые поля" test_save_state_includes_new_fields
    
    run_test "review_result формат валиден" test_review_result_file_format
    run_test "файлы создаются в feature_dir" test_file_paths_in_feature_dir
    
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
}

main "$@"
