#!/usr/bin/env bash
#
# generate-tasks.sh - Generate tasks.md and task files from plan.md
#
# Usage:
#   ./generate-tasks.sh --plan-path PATH
#

set -euo pipefail

PLAN_PATH=""
VERBOSE=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan-path)
                PLAN_PATH="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 --plan-path PATH"
                echo ""
                echo "Parameters:"
                echo "  --plan-path PATH  Path to plan.md (required)"
                echo "  --verbose         Verbose output"
                exit 0
                ;;
            *)
                echo "Error: Unknown parameter: $1" >&2
                exit 1
                ;;
        esac
    done
}

log() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[$(date +'%H:%M:%S')] $1"
    fi
}

parse_dependencies_from_plan() {
    local plan_file="$1"
    local task_id="$2"
    
    local deps_line=$(grep -A 20 "^### $task_id:" "$plan_file" | grep -E "^(Dependencies|depends on):" | head -1)
    
    if [[ -n "$deps_line" ]]; then
        local deps=$(echo "$deps_line" | sed -E 's/^(Dependencies|depends on)://' | grep -oE 'T[0-9]+' | tr '\n' ',' | sed 's/,$//')
        if [[ -n "$deps" ]]; then
            echo "$deps"
            return
        fi
    fi
    
    echo ""
}

generate_tasks() {
    local plan_file="$1"
    local feature_dir="$2"
    
    local tasks_dir="$feature_dir/tasks"
    local tasks_file="$feature_dir/tasks.md"
    
    mkdir -p "$tasks_dir"
    
    local task_ids=()
    local task_titles=()
    
    while IFS= read -r line; do
        if [[ $line =~ ^###\ (T[0-9]+):\ (.*) ]]; then
            task_ids+=("${BASH_REMATCH[1]}")
            task_titles+=("${BASH_REMATCH[2]}")
        fi
    done < "$plan_file"
    
    {
        echo "# Tasks"
        echo ""
        for i in "${!task_ids[@]}"; do
            echo "- [ ] ${task_ids[$i]}: ${task_titles[$i]}"
        done
    } > "$tasks_file"
    
    log "Created: $tasks_file"
    
    for i in "${!task_ids[@]}"; do
        local task_id="${task_ids[$i]}"
        local task_title="${task_titles[$i]}"
        local task_file="$tasks_dir/${task_id}.md"
        
        local deps=$(parse_dependencies_from_plan "$plan_file" "$task_id")
        local deps_yaml="[]"
        if [[ -n "$deps" ]]; then
            deps_yaml="[$(echo "$deps" | sed 's/,/, /g')]"
        fi
        
        cat > "$task_file" << EOF
---
id: $task_id
dependencies: $deps_yaml
---
# $task_id: $task_title

## Context

[Add context from plan]

## Test Specification (RED Phase)

### Test Type
- [ ] Unit (isolated, mocked dependencies)
- [ ] Integration (real dependencies)

### Test Cases
| ID | Scenario | Given | When | Then | Type |
|----|----------|-------|------|------|------|
| T1 | Happy path | valid input | call method | returns success | unit |

### Test Data
\`\`\`yaml
valid_input:
  param1: "example_value"
\`\`\`

### Mocks/Stubs Required
- DependencyName → mock behaviour

### Expected Outcomes
- T1: return value, side effects

## Implementation Specification (GREEN Phase)

[What to implement]

## Refactoring Notes (REFACTOR Phase)

[Potential improvements]

## Acceptance Criteria
- [ ] All test cases pass
- [ ] Coverage ≥ 80% on new code
- [ ] No test smells (AAA, no shared state)

## Constraints

[Technical constraints]
EOF
        
        log "Created: $task_file"
    done
    
    echo "${#task_ids[@]}"
}

main() {
    parse_args "$@"
    
    if [[ -z "$PLAN_PATH" ]]; then
        echo "Error: --plan-path is required" >&2
        exit 1
    fi
    
    if [[ ! -f "$PLAN_PATH" ]]; then
        echo "Error: plan.md not found: $PLAN_PATH" >&2
        exit 1
    fi
    
    local feature_dir=$(dirname "$PLAN_PATH")
    
    echo "🚀 Generating tasks from plan..."
    echo "Plan: $PLAN_PATH"
    echo ""
    
    local task_count
    task_count=$(generate_tasks "$PLAN_PATH" "$feature_dir")
    
    echo ""
    echo "✅ Generated $task_count tasks"
    echo "   Index: $feature_dir/tasks.md"
    echo "   Files: $feature_dir/tasks/"
}

main "$@"
