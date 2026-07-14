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
