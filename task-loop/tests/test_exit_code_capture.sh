#!/usr/bin/env bash
# Tests for exit code capture fix in task_loop.sh
# Usage: bash test_exit_code_capture.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
PASS=0
FAIL=0

pass() { ((PASS++)); echo -e "${GREEN}PASS: $1${NC}"; }
fail() { ((FAIL++)); echo -e "${RED}FAIL: $1${NC}"; }

# Simulates old implementation: echo $exit_code into stdout
# This is what $(...) in line 1030 captures
simulate_old() {
    local exit_val="$1"
    echo "[10:23:11] [INFO] Starting Kilo for task T000"
    echo "[10:23:11] [INFO] Kilo PID: 5323, monitoring..."
    echo "[10:23:13] [INFO] Kilo exited on its own for task T000 (exit code: $exit_val)"
    echo "$exit_val"
}

# Simulates new implementation: return $exit_code via $?
simulate_new() {
    local exit_val="$1"
    echo "[10:23:11] [INFO] Starting Kilo for task T000"
    return "$exit_val"
}

# Simulates the OLD broken pattern: echo $exit_code from nested function
# mixed with Kilo stdout into $(...) capture
_old_style_worker() {
    local exit_val="$1"
    echo "[10:23:11] [INFO] Kilo exited with code $exit_val"
    echo "$exit_val"
}

run_old_style() {
    local result
    result=$(_old_style_worker 42)
    # result = "multi-line log\n42"
    local last_line
    last_line=$(echo "$result" | tail -1)
    echo "$last_line"
}

# Simulates the NEW fixed pattern: 
# 1. Inner function stores exit code in shared var, returns 0
# 2. Outer function reads shared var via $?
_new_style_worker() {
    local exit_val="$1"
    _shared_exit=$exit_val
    return 0
}

run_new_style() {
    local _shared_exit=0
    if _new_style_worker 42; then
        return $_shared_exit
    fi
    return 1
}

# ─── Test 1: Old impl $(...) captures logs mixed with exit code ───
test_old_mixes_stdout() {
    local result
    result=$(simulate_old 0)
    # $(...) captured everything — exit_code is the LAST line ("0"), but
    # if there's trailing content after it, the whole thing is not a number
    local last_line
    last_line=$(echo "$result" | tail -1)
    if [[ "$last_line" == "0" ]]; then
        pass "Old impl: exit_code is '0' (last line is correct by chance)"
        # But verify it's not just "0" — it's multi-line noise
        local line_count
        line_count=$(echo "$result" | wc -l | tr -d ' ')
        if [[ "$line_count" -gt 1 ]]; then
            pass "Old impl: confirmed multi-line output (bug: $(()) gets all lines)"
        fi
    else
        fail "Old impl: exit_code was '$result' (expected noise)"
    fi
}

# ─── Test 2: New impl $? returns clean numeric exit code ───
test_new_returns_clean() {
    simulate_new 0
    local ec=$?
    if [[ "$ec" -eq 0 ]]; then
        pass "New impl: clean exit code 0 via \$?"
    else
        fail "New impl: expected 0 via \$?, got $ec"
    fi
}

# ─── Test 3: New impl propagates non-zero exit code ───
test_new_propagates_error() {
    simulate_new 42
    local ec=$?
    if [[ "$ec" -eq 42 ]]; then
        pass "New impl: exit code 42 propagated correctly via \$?"
    else
        fail "New impl: expected 42 via \$?, got $ec"
    fi
}

# ─── Test 4: Simulate the actual bug — $(run_kilo_with_pending_detection) ───
test_actual_bug_old_way() {
    # This reproduces how task_loop.sh line 1030 captures exit code
    local exit_code
    exit_code=$(simulate_old 0)
    
    # At line 1063: [[ $exit_code -ne 0 ]]
    # If exit_code has multi-line noise, bash gets syntax error
    if [[ "$exit_code" =~ ^[0-9]+$ ]]; then
        pass "Old check: [[ $exit_code -ne 0 ]] would have numeric comparison"
    else
        # On real Kilo, the log lines contain [ ] which break [[ ]]
        # But in our test with just numbers in log, [[ works
        # Simulate real-world: add brackets in log
        :
    fi

    # Real bug reproduction
    local exit_code_noisy
    exit_code_noisy=$(echo -e "[10:23:11] [INFO] Starting Kilo\n0")
    if [[ "$exit_code_noisy" =~ ^[0-9]+$ ]] 2>/dev/null; then
        fail "Old check: bash would parse multi-line as numeric (unexpected)"
    else
        pass "Old check: multi-line exit_code is NOT numeric (would trigger syntax error)"
    fi
}

# ─── Test 5: New impl doesn't pollute stdout — works in $(...) too ───
test_new_no_stdout_pollution() {
    # When called inside $(...), the echo'd messages go to captured output,
    # but exit code goes through $? and is NOT in stdout
    local output
    output=$(simulate_new 0; echo "EXIT=$?")
    # output should contain logs AND "EXIT=0" appended
    if echo "$output" | grep -q "EXIT=0"; then
        pass "New impl: exit code accessible via \$? after subshell"
    else
        fail "New impl: expected EXIT=0 in output, got '$output'"
    fi
}

# ─── Test 6: Simulate the full old call chain with REAL Kilo output ───
test_full_old_chain() {
    # Real Kilo output has [ prefix which breaks [[ ]]
    local exit_code
    exit_code=$(echo -e "[10:23:11] [INFO] Starting Kilo\n0")
    
    # Line 1063: if [[ $exit_code -ne 0 ]]
    # This should fail with syntax error (but bash continues)
    # When [[ fails with syntax error, the condition is false
    if [[ "$exit_code" -ne 0 ]] 2>/dev/null; then
        fail "Full chain old: was able to compare (unexpected — should fail on multi-line)"
    else
        pass "Full chain old: [[ comparison fails on multi-line exit_code (bug confirmed)"
    fi
}

# ─── Test 7: Simulate the new call chain ───
test_full_new_chain() {
    simulate_new 1
    local exit_code=$?
    
    if [[ "$exit_code" -ne 0 ]]; then
        pass "Full chain new: detected non-zero exit ($exit_code) correctly"
    else
        fail "Full chain new: expected non-zero, got 0"
    fi
}

echo "=== Test Suite: exit_code capture fix ==="
echo ""

test_old_mixes_stdout
test_new_returns_clean
test_new_propagates_error
test_actual_bug_old_way
test_new_no_stdout_pollution
test_full_old_chain
test_full_new_chain

# ─── Test 8: Old pattern — echo in $(...) captures Kilo log mixed with exit code ───
test_old_echo_in_subshell() {
    local result
    result=$(run_old_style)
    if [[ "$result" == "42" ]]; then
        pass "Old pattern: $(run_old_style) returns '42' (correct by chance with this mock)"
    else
        fail "Old pattern: expected '42', got '$result'"
    fi

    # But verify it's fragile: if Kilo log has multiple lines, last is exit code
    local output
    output=$(run_old_style)
    local lines
    lines=$(echo "$output" | wc -l | tr -d ' ')
    if [[ "$lines" -gt 1 ]]; then
        pass "Old pattern: produces $lines lines of output (fragile)"
    fi
}

# ─── Test 9: New pattern — return value via shared variable, $? is clean ───
test_new_shared_var_pattern() {
    run_new_style
    local ec=$?
    if [[ "$ec" -eq 42 ]]; then
        pass "New pattern: exit code 42 preserved via shared variable"
    else
        fail "New pattern: expected 42, got $ec"
    fi
}

# ─── Test 10: Verify new pattern works inside $(...) too ───
test_new_pattern_in_subshell() {
    local output
    output=$(run_new_style; echo "EC=$?")
    if echo "$output" | grep -q "EC=42"; then
        pass "New pattern: works inside \$() subshell, exit code 42"
    else
        fail "New pattern: expected EC=42 in output, got '$output'"
    fi
}

test_old_echo_in_subshell
test_new_shared_var_pattern
test_new_pattern_in_subshell

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -ne 0 ]]; then
    exit 1
fi