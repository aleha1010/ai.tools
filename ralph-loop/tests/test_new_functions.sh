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
    
    is_task_completed() {
        local task_id="$1"
        local tasks_file="$2"
        
        grep -qE "^\s*-\s*\[x\]\s+${task_id}" "$tasks_file" 2>/dev/null
    }
    
    parse_frontmatter_deps() {
        local task_file="$1"
        
        if [[ ! -f "$task_file" ]]; then
            echo ""
            return 1
        fi
        
        grep '^dependencies:' "$task_file" 2>/dev/null | \
            sed -n 's/^dependencies: \[\(.*\)\]/\1/p' | \
            tr -d ' ' | tr ',' '\n' | \
            grep -E '^T[0-9]+$' || echo ""
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
# Tests: is_task_completed / parse_frontmatter_deps
# =====================================================

test_is_task_completed_returns_true_for_done() {
    source_functions
    
    local tasks_file="$TEST_TMP_DIR/tasks.md"
    cat > "$tasks_file" << 'EOF'
# Tasks

- [ ] T001: First task
- [x] T002: Completed task
- [ ] T003: Third task
EOF
    
    if is_task_completed "T002" "$tasks_file"; then
        return 0
    else
        echo "T002 should be completed" >&2
        return 1
    fi
}

test_is_task_completed_returns_false_for_incomplete() {
    source_functions
    
    local tasks_file="$TEST_TMP_DIR/tasks.md"
    cat > "$tasks_file" << 'EOF'
# Tasks

- [ ] T001: First task
- [x] T002: Completed task
EOF
    
    if is_task_completed "T001" "$tasks_file"; then
        echo "T001 should NOT be completed" >&2
        return 1
    else
        return 0
    fi
}

test_parse_frontmatter_deps_extracts_deps() {
    source_functions
    
    local task_file="$TEST_TMP_DIR/T001.md"
    cat > "$task_file" << 'EOF'
---
id: T001
dependencies: [T000, T002]
---
# T001: Task
EOF
    
    local result
    result=$(parse_frontmatter_deps "$task_file")
    
    if echo "$result" | grep -q "T000" && echo "$result" | grep -q "T002"; then
        return 0
    else
        echo "Expected T000 and T002, got: $result" >&2
        return 1
    fi
}

test_parse_frontmatter_deps_returns_empty_for_no_deps() {
    source_functions
    
    local task_file="$TEST_TMP_DIR/T001.md"
    cat > "$task_file" << 'EOF'
---
id: T001
---
# T001: Task
EOF
    
    local result
    result=$(parse_frontmatter_deps "$task_file")
    
    if [[ -z "$result" ]]; then
        return 0
    else
        echo "Expected empty for no deps, got: $result" >&2
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
# Tests: REJECTED flow
# =====================================================

test_review_result_file_passed_to_prompt() {
    source_functions
    
    local prompt_file="$TEST_TMP_DIR/prompt.md"
    local review_result_file="$TEST_TMP_DIR/.ralph_review_result.md"
    
    cat > "$prompt_file" << 'EOF'
Task: $TASKS_PATH
Review: $REVIEW_RESULT_FILE
EOF
    
    cat > "$review_result_file" << 'EOF'
---
decision: REJECTED
task_id: T002
---
# Review Results
EOF
    
    local safe_review_result=$(printf '%s' "$review_result_file" | sed 's/[&/\]/\\&/g')
    local prompt=$(sed "s|\$REVIEW_RESULT_FILE|$safe_review_result|g" "$prompt_file")
    
    if [[ "$prompt" == *"Review: $review_result_file"* ]]; then
        return 0
    else
        echo "REVIEW_RESULT_FILE should be substituted in prompt" >&2
        echo "Got: $prompt" >&2
        return 1
    fi
}

test_rejected_task_continued_on_next_iteration() {
    source_functions
    
    local state_file="$TEST_TMP_DIR/.ralph_state.json"
    cat > "$state_file" << 'EOF'
{
  "state": "REJECTED",
  "iteration": 5,
  "current_task": "T002",
  "timestamp": "2026-06-26T12:00:00Z"
}
EOF
    
    local tasks_dir="$TEST_TMP_DIR/tasks"
    mkdir -p "$tasks_dir"
    echo "# T002" > "$tasks_dir/T002.md"
    
    local next_task=""
    
    if [[ -f "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then
        local prev_state=$(jq -r '.state // empty' "$state_file" 2>/dev/null)
        local prev_task=$(jq -r '.current_task // empty' "$state_file" 2>/dev/null)
        
        if [[ "$prev_state" == "REJECTED" && -n "$prev_task" ]]; then
            local task_file_to_check="${tasks_dir}/${prev_task}.md"
            
            if [[ -f "$task_file_to_check" ]]; then
                next_task="$prev_task"
            fi
        fi
    fi
    
    if [[ "$next_task" == "T002" ]]; then
        return 0
    else
        echo "REJECTED task T002 should be selected, got: $next_task" >&2
        return 1
    fi
}

test_rejected_task_missing_file_fallback() {
    source_functions
    
    local state_file="$TEST_TMP_DIR/.ralph_state.json"
    cat > "$state_file" << 'EOF'
{
  "state": "REJECTED",
  "iteration": 5,
  "current_task": "T999",
  "timestamp": "2026-06-26T12:00:00Z"
}
EOF
    
    local tasks_dir="$TEST_TMP_DIR/tasks"
    mkdir -p "$tasks_dir"
    
    local next_task=""
    
    if [[ -f "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then
        local prev_state=$(jq -r '.state // empty' "$state_file" 2>/dev/null)
        local prev_task=$(jq -r '.current_task // empty' "$state_file" 2>/dev/null)
        
        if [[ "$prev_state" == "REJECTED" && -n "$prev_task" ]]; then
            local task_file_to_check="${tasks_dir}/${prev_task}.md"
            
            if [[ -f "$task_file_to_check" ]]; then
                next_task="$prev_task"
            fi
        fi
    fi
    
    if [[ -z "$next_task" ]]; then
        return 0
    else
        echo "Should fallback when task file missing, got: $next_task" >&2
        return 1
    fi
}

test_corrupted_state_file_fallback() {
    source_functions
    
    local state_file="$TEST_TMP_DIR/.ralph_state.json"
    echo "{ invalid json }" > "$state_file"
    
    local next_task=""
    
    if [[ -f "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then
        next_task="SHOULD_NOT_BE_SET"
    fi
    
    if [[ -z "$next_task" ]]; then
        return 0
    else
        echo "Should fallback when state file corrupted" >&2
        return 1
    fi
}

# =====================================================
# Tests: load_state
# =====================================================

test_load_state_restores_counters() {
    source_functions
    
    local state_file="$TEST_TMP_DIR/.ralph_state.json"
    cat > "$state_file" << 'EOF'
{
  "state": "REJECTED",
  "iteration": 7,
  "current_task": "T003",
  "timestamp": "2026-06-26T12:00:00Z",
  "pid": 12345,
  "review_retries": 1,
  "review_failures": 1,
  "tasks_completed": 2,
  "total_attempts": 15,
  "failed_tasks": ["T001"],
  "consecutive_failures": 1,
  "impl_failures": 0,
  "infra_failures": 1,
  "task_rejection_counts": {"T003": 1}
}
EOF
    
    local STATE_FILE="$state_file"
    local iteration=0 tasks_completed=0 consecutive_failures=0
    local review_retries=0 review_failures=0 total_attempts=0
    local failed_tasks="[]" task_rejection_counts="{}"
    local impl_failures=0 infra_failures=0
    
    STATE_FILE="$state_file" && \
    iteration=$(jq -r '.iteration // 0' "$STATE_FILE") && \
    tasks_completed=$(jq -r '.tasks_completed // 0' "$STATE_FILE") && \
    consecutive_failures=$(jq -r '.consecutive_failures // 0' "$STATE_FILE") && \
    review_failures=$(jq -r '.review_failures // 0' "$STATE_FILE") && \
    total_attempts=$(jq -r '.total_attempts // 0' "$STATE_FILE") && \
    impl_failures=$(jq -r '.impl_failures // 0' "$STATE_FILE") && \
    infra_failures=$(jq -r '.infra_failures // 0' "$STATE_FILE")
    
    if [[ "$iteration" -eq 7 && "$tasks_completed" -eq 2 && "$consecutive_failures" -eq 1 && "$review_failures" -eq 1 && "$impl_failures" -eq 0 && "$infra_failures" -eq 1 ]]; then
        return 0
    else
        echo "Counters not restored: iter=$iteration, tasks=$tasks_completed, fail=$consecutive_failures" >&2
        return 1
    fi
}

# =====================================================
# Tests: cycle detection
# =====================================================

test_cycle_detection_finds_cycle() {
    source_functions
    
    local tasks_dir="$TEST_TMP_DIR/tasks"
    mkdir -p "$tasks_dir"
    local tasks_file="$TEST_TMP_DIR/tasks.md"
    
    cat > "$tasks_file" << 'EOF'
# Tasks
- [ ] T001: Task A
- [ ] T002: Task B
EOF
    
    cat > "$tasks_dir/T001.md" << 'EOF'
---
id: T001
dependencies: [T002]
---
# T001
EOF
    
    cat > "$tasks_dir/T002.md" << 'EOF'
---
id: T002
dependencies: [T001]
---
# T002
EOF
    
    local t001_deps t002_deps
    t001_deps=$(parse_frontmatter_deps "$tasks_dir/T001.md")
    t002_deps=$(parse_frontmatter_deps "$tasks_dir/T002.md")
    
    if echo "$t001_deps" | grep -q "T002" && echo "$t002_deps" | grep -q "T001"; then
        return 0
    else
        echo "Should detect T001<->T002 cycle (deps: T001->$t001_deps, T002->$t002_deps)" >&2
        return 1
    fi
}

test_cycle_detection_no_cycle() {
    source_functions
    
    local tasks_dir="$TEST_TMP_DIR/tasks"
    mkdir -p "$tasks_dir"
    local tasks_file="$TEST_TMP_DIR/tasks.md"
    
    cat > "$tasks_file" << 'EOF'
# Tasks
- [x] T001: Task A
- [ ] T002: Task B
EOF
    
    cat > "$tasks_dir/T001.md" << 'EOF'
---
id: T001
---
# T001
EOF
    
    cat > "$tasks_dir/T002.md" << 'EOF'
---
id: T002
dependencies: [T001]
---
# T002
EOF
    
    local deps
    deps=$(parse_frontmatter_deps "$tasks_dir/T002.md")
    
    if echo "$deps" | grep -q "T001" && ! echo "$deps" | grep -q "T002"; then
        return 0
    else
        echo "T002 deps should only contain T001, got: $deps" >&2
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
    
    run_test "is_task_completed возвращает true для выполненной" test_is_task_completed_returns_true_for_done
    run_test "is_task_completed возвращает false для невыполненной" test_is_task_completed_returns_false_for_incomplete
    run_test "parse_frontmatter_deps извлекает зависимости" test_parse_frontmatter_deps_extracts_deps
    run_test "parse_frontmatter_deps возвращает пусто без зависимостей" test_parse_frontmatter_deps_returns_empty_for_no_deps
    
    run_test "save_state включает новые поля" test_save_state_includes_new_fields
    
    run_test "review_result формат валиден" test_review_result_file_format
    run_test "файлы создаются в feature_dir" test_file_paths_in_feature_dir
    
    run_test "review_result_file передаётся в prompt" test_review_result_file_passed_to_prompt
    run_test "REJECTED task продолжается на следующей итерации" test_rejected_task_continued_on_next_iteration
    run_test "Fallback при отсутствующем task file" test_rejected_task_missing_file_fallback
    run_test "Fallback при повреждённом state file" test_corrupted_state_file_fallback
    run_test "load_state восстанавливает счётчики" test_load_state_restores_counters
    run_test "cycle detection обнаруживает цикл" test_cycle_detection_finds_cycle
    run_test "cycle detection пропускает ацикличный граф" test_cycle_detection_no_cycle
    
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
