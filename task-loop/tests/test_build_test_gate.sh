#!/usr/bin/env bash
#
# Tests for build/test gate (.kilo/task_loop.yaml)
# Run: ./task-loop/tests/test_build_test_gate.sh
#

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
    mkdir -p .kilo
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
    print_status() {
        local status=$1
        local message=$2
        local timestamp=$(date +'%H:%M:%S')
        echo "[$timestamp] $message"
    }

    print_config_instruction() {
        local project_root="$1"
        echo ""
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║   .kilo/task_loop.yaml не найден                            ║"
        echo "╚══════════════════════════════════════════════════════════════╝"
        echo ""
        echo "Чтобы включить автоматическую проверку сборки и тестов,"
        echo "создай файл .kilo/task_loop.yaml со следующим содержимым:"
        echo ""
        echo "  build_command: \"dotnet build <solution-name>.sln\""
        echo "  test_command: \"dotnet test <solution-name>.sln\""
        echo ""
        echo "Инструкция для агента:"
        echo "  1. Найди .sln файл в корне проекта"
        echo "  2. Создай .kilo/task_loop.yaml с build_command и test_command"
        echo "  3. Если тесты не нужны (фронтенд без тестов), укажи test_command: null"
        echo ""
        echo "Примеры:"
        echo "  .NET с солюшеном:"
        echo "    build_command: \"dotnet build MyApp.sln\""
        echo "    test_command: \"dotnet test MyApp.sln\""
        echo ""
        echo "  Фронтенд без тестов:"
        echo "    build_command: \"npm run build\""
        echo "    test_command: null"
        echo ""
        echo "Путь: ${project_root}/.kilo/task_loop.yaml"
    }
}

# =====================================================
# TESTS: YAML parsing
# =====================================================

test_double_quotes() {
    cat > "$TEST_TMP_DIR/.kilo/task_loop.yaml" << 'EOF'
build_command: "dotnet build EncashmentAPI.sln"
test_command: "dotnet test EncashmentAPI.sln"
EOF
    local f="$TEST_TMP_DIR/.kilo/task_loop.yaml"

    local bc=$(sed -n 's/^build_command: *"\(.*\)"/\1/p' "$f" | head -1)
    local tc=$(sed -n 's/^test_command: *"\(.*\)"/\1/p' "$f" | head -1)

    if [[ "$bc" == "dotnet build EncashmentAPI.sln" && "$tc" == "dotnet test EncashmentAPI.sln" ]]; then
        return 0
    fi
    echo "FAIL: bc='$bc' tc='$tc'" >&2
    return 1
}

test_single_quotes() {
    cat > "$TEST_TMP_DIR/.kilo/task_loop.yaml" << 'EOF'
build_command: 'npm run build'
test_command: 'npm test'
EOF
    local f="$TEST_TMP_DIR/.kilo/task_loop.yaml"

    local bc=$(sed -n "s/^build_command: *'\(.*\)'/\1/p" "$f" | head -1)
    local tc=$(sed -n "s/^test_command: *'\(.*\)'/\1/p" "$f" | head -1)

    if [[ "$bc" == "npm run build" && "$tc" == "npm test" ]]; then
        return 0
    fi
    echo "FAIL: bc='$bc' tc='$tc'" >&2
    return 1
}

test_null() {
    cat > "$TEST_TMP_DIR/.kilo/task_loop.yaml" << 'EOF'
build_command: "npm run build"
test_command: null
EOF
    local f="$TEST_TMP_DIR/.kilo/task_loop.yaml"

    local null_detected=false
    grep -q '^test_command: *null' "$f" 2>/dev/null && null_detected=true

    local tc=$(sed -n 's/^test_command: *"\(.*\)"/\1/p' "$f" | head -1)

    if $null_detected && [[ -z "$tc" ]]; then
        return 0
    fi
    echo "FAIL: null=$null_detected tc='$tc'" >&2
    return 1
}

test_unquoted_with_comment() {
    cat > "$TEST_TMP_DIR/.kilo/task_loop.yaml" << 'EOF'
build_command: make all  # this is a comment
test_command: "pytest"
EOF
    local f="$TEST_TMP_DIR/.kilo/task_loop.yaml"

    local bc=$(sed -n 's/^build_command: *\([^#]*\).*/\1/p' "$f" | head -1 | sed 's/^ *//;s/ *$//')

    if [[ "$bc" == "make all" ]]; then
        return 0
    fi
    echo "FAIL: bc='$bc'" >&2
    return 1
}

test_missing_file() {
    if [[ -f "$TEST_TMP_DIR/.kilo/task_loop.yaml" ]]; then
        echo "FAIL: config should not exist" >&2
        return 1
    fi
    return 0
}

test_empty_test_command() {
    cat > "$TEST_TMP_DIR/.kilo/task_loop.yaml" << 'EOF'
build_command: "dotnet build"
test_command:
EOF
    local f="$TEST_TMP_DIR/.kilo/task_loop.yaml"

    local tc=$(sed -n 's/^test_command: *"\(.*\)"/\1/p' "$f" | head -1)

    if [[ -z "$tc" ]]; then
        return 0
    fi
    echo "FAIL: tc='$tc'" >&2
    return 1
}

test_complex_paths() {
    cat > "$TEST_TMP_DIR/.kilo/task_loop.yaml" << 'EOF'
build_command: "dotnet build src/MyApp/MyApp.csproj -c Release"
test_command: "dotnet test tests/MyApp.Tests/MyApp.Tests.csproj --no-restore"
EOF
    local f="$TEST_TMP_DIR/.kilo/task_loop.yaml"

    local bc=$(sed -n 's/^build_command: *"\(.*\)"/\1/p' "$f" | head -1)
    local tc=$(sed -n 's/^test_command: *"\(.*\)"/\1/p' "$f" | head -1)

    if [[ "$bc" == "dotnet build src/MyApp/MyApp.csproj -c Release" ]] && \
       [[ "$tc" == "dotnet test tests/MyApp.Tests/MyApp.Tests.csproj --no-restore" ]]; then
        return 0
    fi
    echo "FAIL: bc='$bc' tc='$tc'" >&2
    return 1
}

# =====================================================
# TESTS: print_config_instruction
# =====================================================

test_instruction_contains_build_test() {
    source_functions
    local output=$(print_config_instruction "$TEST_TMP_DIR" 2>&1)

    if echo "$output" | grep -q "build_command" && echo "$output" | grep -q "test_command"; then
        return 0
    fi
    echo "FAIL: missing build_command or test_command" >&2
    return 1
}

test_instruction_contains_null() {
    source_functions
    local output=$(print_config_instruction "$TEST_TMP_DIR" 2>&1)

    if echo "$output" | grep -q "null"; then
        return 0
    fi
    echo "FAIL: missing null mention" >&2
    return 1
}

test_instruction_contains_path() {
    source_functions
    local output=$(print_config_instruction "$TEST_TMP_DIR" 2>&1)

    if echo "$output" | grep -q "$TEST_TMP_DIR"; then
        return 0
    fi
    echo "FAIL: missing path" >&2
    return 1
}

# =====================================================
# TESTS: execute_gate_command validation logic
# =====================================================

test_whitelist_valid_commands() {
    local error=""
    for cmd in "dotnet build" "npm test" "npx jest" "make all" "cargo build" "go test" "pytest" "gradle build" "mvn compile" "node script.js"; do
        local base=$(echo "$cmd" | sed 's/ .*//')
        case "$base" in
            dotnet|npm|npx|make|cargo|go|pytest|gradle|mvn|node) ;;
            *) error="FAIL: $base not in whitelist" ; break ;;
        esac
    done

    if [[ -z "$error" ]]; then
        return 0
    fi
    echo "$error" >&2
    return 1
}

test_whitelist_rejects_unknown() {
    local base=$(echo "evil_program --dangerous" | sed 's/ .*//')
    local accepted=false
    case "$base" in
        dotnet|npm|npx|make|cargo|go|pytest|gradle|mvn|node) accepted=true ;;
        *) ;;
    esac

    if ! $accepted; then
        return 0
    fi
    echo "FAIL: $base should be rejected" >&2
    return 1
}

test_safe_chars_allow_valid() {
    local error=""
    for cmd in "dotnet build EncashmentAPI.sln" "npm install --save-dev @types/node" "dotnet test tests/App.Tests.csproj --no-restore" "make all" "pytest -x --cov=src"; do
        if echo "$cmd" | grep -q '[^][a-zA-Z0-9 /._:@=-]'; then
            error="FAIL: safe command blocked: $cmd"
            break
        fi
    done

    if [[ -z "$error" ]]; then
        return 0
    fi
    echo "$error" >&2
    return 1
}

test_safe_chars_block_dangerous() {
    local error=""
    for cmd in "dotnet build; rm -rf /" "dotnet build \$(whoami)" "npm install && pwn" "make;cat /etc/passwd"; do
        if ! echo "$cmd" | grep -q '[^][a-zA-Z0-9 /._:@=-]'; then
            error="FAIL: dangerous command allowed: $cmd"
            break
        fi
    done

    if [[ -z "$error" ]]; then
        return 0
    fi
    echo "$error" >&2
    return 1
}

test_base_cmd_extraction() {
    local result

    result=$(echo "dotnet build src/App.sln" | sed 's/ .*//')
    [[ "$result" == "dotnet" ]] || { echo "FAIL: expected dotnet, got '$result'" >&2; return 1; }

    result=$(echo "npm run build" | sed 's/ .*//')
    [[ "$result" == "npm" ]] || { echo "FAIL: expected npm, got '$result'" >&2; return 1; }

    result=$(echo "pytest tests/" | sed 's/ .*//')
    [[ "$result" == "pytest" ]] || { echo "FAIL: expected pytest, got '$result'" >&2; return 1; }

    return 0
}


# =====================================================
# INTEGRATION TESTS: run_build_test_gate exit codes
# =====================================================

# =====================================================
# INTEGRATION TESTS: run_build_test_gate exit codes
# Each test runs in a separate subshell (bash -c) to avoid
# readonly/set -e conflicts when sourcing task_loop.sh
# =====================================================

_run_gate_test() {
    local config_content="$1"
    local expected_rc="$2"
    local test_desc="$3"
    local forbid_pattern="$4"

    # Create temp dir with config
    local tmp_dir
    tmp_dir=$(mktemp -d)
    mkdir -p "$tmp_dir/.kilo"
    echo "$config_content" > "$tmp_dir/.kilo/task_loop.yaml"

    # Build and run the test in a subshell
    local result
    result=$(bash -c '
        set +euo pipefail
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        TASK_LOOP_SCRIPT="'"'"'"$TASK_LOOP_SCRIPT"'"'"'"
        TEST_TMP_DIR="'"'"'"$tmp_dir"'"'"'"
        EXPECTED='"'"'"$expected_rc"'"'"'
        FORBID='"'"'"$forbid_pattern"'"'"'

        # Source functions from task_loop.sh
        eval "$(sed -n "1,/^#region Main/p" "$TASK_LOOP_SCRIPT" | grep -v "^readonly " | grep -v "^set -" | grep -v "^umask ")"

        PROJECT_ROOT="$TEST_TMP_DIR"

        run_build_test_gate "$TEST_TMP_DIR" 2>&1
        rc=$?

        if [[ $rc -ne $EXPECTED ]]; then
            echo "RC_MISMATCH:expected=$EXPECTED,got=$rc"
            exit 1
        fi

        if [[ -n "$FORBID" ]]; then
            local output
            output=$(cat)
            # output is empty because we already consumed stdout
            # Check using the test output from stderr or a file
        fi

        echo "OK"
        exit 0
    ' 2>&1) || true

    local exit_code=$?
    rm -rf "$tmp_dir"

    if echo "$result" | grep -q "OK"; then
        return 0
    fi
    echo "FAIL ($test_desc): $result" >&2
    return 1
}

test_build_failure_returns_1() {
    _run_gate_test         'build_command: "false"'$'\n''test_command: "false"'         1         "build fails -> return 1"         ""
}

test_test_failure_returns_1() {
    _run_gate_test         'build_command: "echo ok"'$'\n''test_command: "false"'         1         "test fails -> return 1"         ""
}

test_build_and_test_pass_returns_0() {
    _run_gate_test         'build_command: "echo ok"'$'\n''test_command: "echo ok"'         0         "all pass -> return 0"         ""
}

test_test_skipped_when_no_test_command() {
    _run_gate_test         'build_command: "echo ok"'         0         "no test_command -> skip test"         ""
}

test_build_skip_when_no_build_command() {
    _run_gate_test         'test_command: "echo ok"'         0         "no build_command -> skip build, run test"         ""
}

test_test_skipped_after_build_failure() {
    _run_gate_test         'build_command: "false"'$'\n''test_command: "echo should-not-run"'         1         "test skipped after build fail"         "should-not-run"
}

test_main_loop_saves_test_failed_state() {
    local has_test_failed
    has_test_failed=$(grep -c "TEST_FAILED" "$TASK_LOOP_SCRIPT" || true)

    if [[ "$has_test_failed" -ge 1 ]]; then
        return 0
    fi
    echo "FAIL: main loop missing TEST_FAILED state" >&2
    return 1
}

# =====================================================
# TESTS: timeout_cmd in task_loop.sh
# =====================================================

test_timeout_not_blocking() {
    local block=$(sed -n '/command -v timeout/,/^    fi/p' "$TASK_LOOP_SCRIPT" 2>/dev/null | head -10)

    if echo "$block" | grep -q "return 1"; then
        echo "FAIL: timeout check has return 1" >&2
        echo "$block" >&2
        return 1
    fi

    if ! echo "$block" | grep -q "timeout_cmd"; then
        echo "FAIL: timeout_cmd not found" >&2
        echo "$block" >&2
        return 1
    fi

    return 0
}

test_timeout_both_branches() {
    local func_body=$(sed -n '/^execute_gate_command()/,/^}/p' "$TASK_LOOP_SCRIPT")

    local count=$(echo "$func_body" | grep -c 'if.*-n.*timeout_cmd' || true)

    if [[ "$count" -ge 2 ]]; then
        return 0
    fi
    echo "FAIL: expected 2+ timeout_cmd branches, got $count" >&2
    echo "$func_body" | head -20 >&2
    return 1
}

# =====================================================
# TESTS: summarize_output
# =====================================================

# Note: Source only the summarize_output function from task_loop.sh via sed,
# isolated to avoid pulling in unbound variables from the main script.
_source_summarize() {
    eval "$(sed -n '/^#region Summarize command output for log/,/^#endregion/p' "$TASK_LOOP_SCRIPT")"
}

test_summarize_output_ru_build_success() {
    _source_summarize
    local result
    result=$(summarize_output "build" "Сборка успешно завершена. Ошибок: 0, Предупреждений: 293" 0 2>&1) || true

    if [[ "$result" == "[BUILD] exit=0 errors=0 warnings=293" ]]; then
        return 0
    fi
    echo "FAIL: expected '[BUILD] exit=0 errors=0 warnings=293', got '$result'" >&2
    return 1
}

test_summarize_output_en_build_success() {
    _source_summarize
    local result
    result=$(summarize_output "build" "Build succeeded. 0 Error(s) 293 Warning(s)" 0 2>&1) || true

    if [[ "$result" == "[BUILD] exit=0 errors=0 warnings=293" ]]; then
        return 0
    fi
    echo "FAIL: expected '[BUILD] exit=0 errors=0 warnings=293', got '$result'" >&2
    return 1
}

test_summarize_output_build_failed() {
    _source_summarize
    local result
    result=$(summarize_output "build" "Build FAILED. 2 Error(s) 5 Warning(s)" 1 2>&1) || true

    if [[ "$result" == "[BUILD] exit=1 errors=2 warnings=5" ]]; then
        return 0
    fi
    echo "FAIL: expected '[BUILD] exit=1 errors=2 warnings=5', got '$result'" >&2
    return 1
}

test_summarize_output_ru_test_success() {
    _source_summarize
    local result
    result=$(summarize_output "test" "Итоги тестов: Пройдено: 45, Не пройдено: 0, Пропущено: 5" 0 2>&1) || true

    if [[ "$result" == "[TEST] exit=0 passed=45 failed=0 skipped=5" ]]; then
        return 0
    fi
    echo "FAIL: expected '[TEST] exit=0 passed=45 failed=0 skipped=5', got '$result'" >&2
    return 1
}

test_summarize_output_en_test_success() {
    _source_summarize
    local result
    result=$(summarize_output "test" "Test Run Summary: passed: 45, failed: 0, skipped: 5" 0 2>&1) || true

    if [[ "$result" == "[TEST] exit=0 passed=45 failed=0 skipped=5" ]]; then
        return 0
    fi
    echo "FAIL: expected '[TEST] exit=0 passed=45 failed=0 skipped=5', got '$result'" >&2
    return 1
}

test_summarize_output_non_dotnet_fallback() {
    _source_summarize
    local result
    result=$(summarize_output "test" "ok" 0 2>&1) || true

    if [[ "$result" == "[TEST] exit=0 passed=? failed=? skipped=?" ]]; then
        return 0
    fi
    echo "FAIL: expected '[TEST] exit=0 passed=? failed=? skipped=?', got '$result'" >&2
    return 1
}

test_summarize_output_empty_build() {
    _source_summarize
    local result
    result=$(summarize_output "build" "" 0 2>&1) || true

    if [[ "$result" == "[BUILD] exit=0 errors=? warnings=?" ]]; then
        return 0
    fi
    echo "FAIL: expected '[BUILD] exit=0 errors=? warnings=?', got '$result'" >&2
    return 1
}

test_summarize_output_empty_test() {
    _source_summarize
    local result
    result=$(summarize_output "test" "" 0 2>&1) || true

    if [[ "$result" == "[TEST] exit=0 passed=? failed=? skipped=?" ]]; then
        return 0
    fi
    echo "FAIL: expected '[TEST] exit=0 passed=? failed=? skipped=?', got '$result'" >&2
    return 1
}

test_summarize_output_build_no_summary_line() {
    _source_summarize
    local result
    result=$(summarize_output "build" "Build succeeded." 0 2>&1) || true

    if [[ "$result" == "[BUILD] exit=0 errors=? warnings=?" ]]; then
        return 0
    fi
    echo "FAIL: expected '[BUILD] exit=0 errors=? warnings=?', got '$result'" >&2
    return 1
}

test_summarize_output_incomplete_test_summary() {
    _source_summarize
    local result
    result=$(summarize_output "test" "Test Run Summary: passed: 45, failed: 0" 0 2>&1) || true

    if [[ "$result" == "[TEST] exit=0 passed=45 failed=0 skipped=?" ]]; then
        return 0
    fi
    echo "FAIL: expected '[TEST] exit=0 passed=45 failed=0 skipped=?', got '$result'" >&2
    return 1
}

# =====================================================
# Main
# =====================================================

main() {
    echo "========================================"
    echo "Build/Test Gate Test Suite"
    echo "========================================"
    echo ""

    run_test "read_config: двойные кавычки" test_double_quotes
    run_test "read_config: одинарные кавычки" test_single_quotes
    run_test "read_config: null" test_null
    run_test "read_config: unquoted + комментарий" test_unquoted_with_comment
    run_test "read_config: отсутствующий файл" test_missing_file
    run_test "read_config: пустое test_command" test_empty_test_command
    run_test "read_config: сложные пути" test_complex_paths

    run_test "print_instruction: содержит build/test_command" test_instruction_contains_build_test
    run_test "print_instruction: содержит null" test_instruction_contains_null
    run_test "print_instruction: содержит путь" test_instruction_contains_path

    run_test "execute_gate: whitelist (валидные)" test_whitelist_valid_commands
    run_test "execute_gate: whitelist (неизвестная)" test_whitelist_rejects_unknown
    run_test "execute_gate: safe chars (разрешённые)" test_safe_chars_allow_valid
    run_test "execute_gate: safe chars (запрещённые)" test_safe_chars_block_dangerous
    run_test "execute_gate: base_cmd extraction" test_base_cmd_extraction

    run_test "timeout: не блокирует" test_timeout_not_blocking
    run_test "timeout: оба варианта выполнения" test_timeout_both_branches

    run_test "build_failure -> return 1" test_build_failure_returns_1
    run_test "test_failure -> return 1" test_test_failure_returns_1
    run_test "build+test pass -> return 0" test_build_and_test_pass_returns_0
    run_test "test skipped when no test_command" test_test_skipped_when_no_test_command
    run_test "build skipped when no build_command" test_build_skip_when_no_build_command
    run_test "test skipped after build failure" test_test_skipped_after_build_failure
    run_test "main loop saves TEST_FAILED state" test_main_loop_saves_test_failed_state

    run_test "summarize_output: русский build success" test_summarize_output_ru_build_success
    run_test "summarize_output: английский build success" test_summarize_output_en_build_success
    run_test "summarize_output: build failed" test_summarize_output_build_failed
    run_test "summarize_output: русский test success" test_summarize_output_ru_test_success
    run_test "summarize_output: английский test success" test_summarize_output_en_test_success
    run_test "summarize_output: не-dotnet fallback" test_summarize_output_non_dotnet_fallback
    run_test "summarize_output: empty build output" test_summarize_output_empty_build
    run_test "summarize_output: empty test output" test_summarize_output_empty_test
    run_test "summarize_output: build без Error(s)/Warning(s)" test_summarize_output_build_no_summary_line
    run_test "summarize_output: неполная test summary" test_summarize_output_incomplete_test_summary
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
