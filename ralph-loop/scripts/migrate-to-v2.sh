#!/usr/bin/env bash
#
# migrate-to-v2.sh - Migrate from specs/ to features/ structure
#
# Usage:
#   ./migrate-to-v2.sh --specs-dir PATH
#

set -euo pipefail

SPECS_DIR=""
DRY_RUN=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --specs-dir)
                SPECS_DIR="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 --specs-dir PATH [--dry-run]"
                echo ""
                echo "Parameters:"
                echo "  --specs-dir PATH  Path to specs/ directory (required)"
                echo "  --dry-run         Show what would be done without making changes"
                exit 0
                ;;
            *)
                echo "Error: Unknown parameter: $1" >&2
                exit 1
                ;;
        esac
    done
}

migrate_feature() {
    local spec_dir="$1"
    local feature_name=$(basename "$spec_dir")
    local parent_dir=$(dirname "$spec_dir")
    local features_dir="${parent_dir/specs/features}"
    local feature_dir="$features_dir/$feature_name"
    
    echo "Migrating: $spec_dir → $feature_dir"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY RUN] Would create: $feature_dir"
        echo "  [DRY RUN] Would create: $feature_dir/tasks/"
        return
    fi
    
    mkdir -p "$feature_dir/tasks"
    
    if [[ -f "$spec_dir/tasks.md" ]]; then
        cp "$spec_dir/tasks.md" "$feature_dir/tasks.md"
        echo "  Copied: tasks.md"
        
        while IFS= read -r line; do
            if echo "$line" | grep -qE '^\s*-\s*\[([x ])\]\s+T[0-9]+'; then
                local task_id=$(echo "$line" | grep -oE 'T[0-9]+' | head -1)
                local status=$(echo "$line" | grep -oE '\[([x ])\]' | tr -d '[]')
                local title=$(echo "$line" | sed 's/^\s*-\s*\[[x ]\]\s*//' | sed 's/T[0-9]*:\s*//')
                
                local task_file="$feature_dir/tasks/${task_id}.md"
                
                local status_marker=""
                if [[ "$status" == "x" ]]; then
                    status_marker="completed"
                fi
                
                cat > "$task_file" << EOF
---
id: $task_id
dependencies: []
status: $status_marker
---
# $task_id: $title

## Context

[Migrated from $spec_dir/tasks.md]

## Test Specification (RED Phase)

### Test Type
- [ ] Unit (isolated, mocked dependencies)
- [ ] Integration (real dependencies)

### Test Cases
| ID | Scenario | Given | When | Then | Type |
|----|----------|-------|------|------|------|
| T1 | Happy path | valid input | call method | returns success | unit |

## Implementation Specification (GREEN Phase)

[What to implement]

## Acceptance Criteria
- [ ] All test cases pass
- [ ] Coverage ≥ 80% on new code
EOF
                
                echo "  Created: tasks/$task_id.md"
            fi
        done < "$spec_dir/tasks.md"
    fi
    
    if [[ -f "$spec_dir/plan.md" ]]; then
        cp "$spec_dir/plan.md" "$feature_dir/plan.md"
        echo "  Copied: plan.md"
    fi
    
    if [[ -f "$spec_dir/progress.md" ]]; then
        cp "$spec_dir/progress.md" "$feature_dir/progress.md"
        echo "  Copied: progress.md"
    fi
    
    echo "  ✅ Migrated successfully"
}

main() {
    parse_args "$@"
    
    if [[ -z "$SPECS_DIR" ]]; then
        echo "Error: --specs-dir is required" >&2
        exit 1
    fi
    
    if [[ ! -d "$SPECS_DIR" ]]; then
        echo "Error: specs directory not found: $SPECS_DIR" >&2
        exit 1
    fi
    
    echo "🚀 Migrating from v1 (specs/) to v2 (features/)"
    echo "Source: $SPECS_DIR"
    echo "Dry run: $DRY_RUN"
    echo ""
    
    local count=0
    
    for spec_feature in "$SPECS_DIR"/*/; do
        if [[ -d "$spec_feature" ]]; then
            migrate_feature "$spec_feature"
            ((count++))
        fi
    done
    
    echo ""
    echo "✅ Migrated $count features"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        echo "This was a dry run. Remove --dry-run to apply changes."
    else
        echo ""
        echo "Next steps:"
        echo "1. Review generated files in features/"
        echo "2. Fill in task specifications (test cases, implementation details)"
        echo "3. Update dependencies in task YAML frontmatter"
        echo "4. Run: ./ralph_loop.sh --tasks-path features/001-auth/tasks.md"
    fi
}

main "$@"
