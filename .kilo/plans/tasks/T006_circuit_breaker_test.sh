#!/bin/bash
# ==============================================================================
# T006: Circuit Breaker Test - 3 Consecutive Failures
# ==============================================================================
# Purpose: Verify circuit breaker mechanism triggers after 3 consecutive failures
#
# Expected Flow:
#   Iteration 1: T006 fails → consecutive_failures=1, backoff 2s
#   Iteration 2: T006 fails → consecutive_failures=2, backoff 4s
#   Iteration 3: T006 fails → consecutive_failures=3, backoff 8s
#   Circuit breaker triggers → State: FAILED → Exit with error
#
# Usage:
#   ./T006_circuit_breaker_test.sh [EXIT_CODE] [ERROR_MESSAGE]
#
# Arguments:
#   EXIT_CODE      - Custom exit code (default: 1)
#   ERROR_MESSAGE  - Custom error message (default: "Simulating circuit breaker failure")
#
# Exit Codes:
#   1 (or custom) - Always exits with non-zero to simulate failure
# ==============================================================================

EXIT_CODE="${1:-1}"
ERROR_MESSAGE="${2:-Simulating circuit breaker failure}"

echo "$ERROR_MESSAGE" >&2
exit "$EXIT_CODE"
