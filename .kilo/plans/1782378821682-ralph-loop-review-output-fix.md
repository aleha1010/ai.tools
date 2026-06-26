# Plan: Ralph Loop Review Output Architecture Fix

**Date:** 2026-06-26
**Status:** Ready for Implementation

---

## Problem Statement

Ralph Loop fails to parse `kilo run --auto` output because:
1. Tool outputs from previous sessions contain `"Error:"` in JSON format
2. Current grep-based parsing triggers false positives
3. Review coordinator writes to stdout, not to a structured file
4. Files scattered across `$PROJECT_ROOT` instead of `$FEATURE_DIR`
5. No atomic writes → corrupted files on process crash

---

## Decisions Summary

| Decision | Choice |
|----------|--------|
| Review result format | Markdown + YAML frontmatter |
| Who writes review result | Review coordinator |
| File path | `$FEATURE_DIR/.ralph_review_result.md` |
| Files per review | One file for Ralph Loop + implementer |
| File locations | All in `$FEATURE_DIR/` |
| Error handling | Retry 2x → Mark failed → Escalate |
| Pending tasks format | JSON (unchanged) |
| State format | JSON with new fields |
| YAML parsing | sed + grep (no yq dependency) |

---

## Implementation Tasks

### Task 1: Update file paths in `ralph_loop.sh`

**File:** `ralph-loop/scripts/ralph_loop.sh`

**Changes:**

```bash
# Around line 583-586, change from:
LOG_FILE="${PROJECT_ROOT}/.ralph_loop.log"
STATE_FILE="${PROJECT_ROOT}/.ralph_state.json"
PENDING_TASKS_FILE="${PROJECT_ROOT}/.ralph_pending_tasks.json"

# To (after FEATURE_DIR is defined):
LOG_FILE="${FEATURE_DIR}/.ralph_loop.log"
STATE_FILE="${FEATURE_DIR}/.ralph_state.json"
PENDING_TASKS_FILE="${FEATURE_DIR}/.ralph_pending_tasks.json"
REVIEW_RESULT_FILE="${FEATURE_DIR}/.ralph_review_result.md"
```

**Note:** This requires moving the file path definitions AFTER `FEATURE_DIR` is calculated (around line 618).

---

### Task 2: Add atomic_write helper function

**File:** `ralph-loop/scripts/ralph_loop.sh`

**Add after line 100 (after helper functions):**

```bash
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
```

---

### Task 3: Update save_state() with new fields

**File:** `ralph-loop/scripts/ralph_loop.sh`

**Replace function (around line 392-406):**

```bash
save_state() {
    local state="$1"
    local iteration="$2"
    local current_task="$3"
    
    cat > "$STATE_FILE" <<STATE_JSON
{
  "state": "$state",
  "iteration": $iteration,
  "current_task": "$current_task",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pid": $$,
  "review_retries": ${review_retries:-0},
  "failed_tasks": $(echo "${failed_tasks:-[]}" | jq -c . 2>/dev/null || echo "[]"),
  "consecutive_failures": ${consecutive_failures:-0}
}
STATE_JSON
}
```

---

### Task 4: Add parse_frontmatter_decision function

**File:** `ralph-loop/scripts/ralph_loop.sh`

**Add after atomic_write function:**

```bash
parse_frontmatter_decision() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        echo ""
        return 1
    fi
    
    # Extract decision from YAML frontmatter
    # Format: decision: APPROVED or decision: REJECTED
    sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null | \
        sed '1d;$d' | \
        grep "^decision:" | \
        head -1 | \
        cut -d: -f2 | \
        tr -d ' "'
}
```

---

### Task 5: Rewrite run_review_gate()

**File:** `ralph-loop/scripts/ralph_loop.sh`

**Replace function (around line 418-507):**

```bash
run_review_gate() {
    local iteration=$1
    local task_id=$2
    local pending_file=$3
    
    if [[ "$NO_REVIEW" == "true" ]]; then
        print_status "info" "Review gate отключён (--no-review)"
        return 0
    fi
    
    print_phase "ФАЗА 2: Review Gate" "Проверка задачи $task_id"
    
    # Remove old result file
    rm -f "$REVIEW_RESULT_FILE"
    
    # Build prompt with file paths
    local safe_tasks_path=$(printf '%s' "$TASKS_PATH" | sed 's/[&/\]/\\&/g')
    local safe_pending_file=$(printf '%s' "$pending_file" | sed 's/[&/\]/\\&/g')
    local safe_review_result=$(printf '%s' "$REVIEW_RESULT_FILE" | sed 's/[&/\]/\\&/g')
    
    local PROMPT=$(sed "s|\$TASKS_PATH|$safe_tasks_path|g" "$REVIEW_PROMPT_FILE")
    PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$safe_pending_file|g" <<< "$PROMPT")
    PROMPT=$(sed "s|\$REVIEW_RESULT_FILE|$safe_review_result|g" <<< "$PROMPT")
    
    # Run review coordinator
    set +e
    $KILO_CMD run --auto "$PROMPT"
    local exit_code=$?
    set -e
    
    # Check if result file was created
    if [[ ! -f "$REVIEW_RESULT_FILE" ]]; then
        ((review_retries++))
        
        if [[ $review_retries -ge 2 ]]; then
            print_status "error" "Review failed after $review_retries retries"
            mark_task_failed "$task_id"
            create_escalation_for_review_failure "$task_id"
            return 2
        fi
        
        print_status "warning" "Review result not found, retrying ($review_retries/2)"
        return 1
    fi
    
    # Parse decision from YAML frontmatter
    local decision
    decision=$(parse_frontmatter_decision "$REVIEW_RESULT_FILE")
    
    if [[ "$decision" == "APPROVED" ]]; then
        print_status "success" "Review ПРОЙДЕН — Задача $task_id одобрена"
        echo ""
        review_retries=0
        return 0
        
    elif [[ "$decision" == "REJECTED" ]]; then
        print_status "error" "Review ОТКЛОНЁН — Задаче $task_id требуются исправления"
        echo ""
        print_status "info" "Исправления описаны в: $REVIEW_RESULT_FILE"
        review_retries=0
        return 1
        
    else
        print_status "error" "Некорректный decision в review result: '$decision'"
        print_status "info" "Файл: $REVIEW_RESULT_FILE"
        return 2
    fi
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

create_escalation_for_review_failure() {
    local task_id="$1"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    cat > "${FEATURE_DIR}/.escalation_handoff.md" <<EOF
# Escalation: Review Coordinator Failure

**Task ID:** $task_id
**Timestamp:** $timestamp
**Severity:** BLOCKER

## Problem

Review coordinator failed to create result file after $review_retries attempts.

## Required Actions

1. Review coordinator logs for errors
2. Check if review coordinator prompt is correct
3. Verify Kilo daemon is running
4. Check disk space and permissions in $FEATURE_DIR

## State

- Iteration: $iteration
- Consecutive failures: $consecutive_failures
- Failed tasks: ${failed_tasks:-[]}
EOF
    
    print_status "info" "Escalation created: ${FEATURE_DIR}/.escalation_handoff.md"
}
```

---

### Task 6: Update ralph-review.md prompt

**File:** `ralph-loop/prompts/ralph-review.md`

**Replace entire file:**

```markdown
ВАЖНО: Отвечай строго на русском языке.

Ты — review coordinator. Запусти reviewers согласно схеме автовыбора.

## Входные данные

- Файл задач: $TASKS_PATH
- Файл с выполненной задачей: $PENDING_TASKS_FILE
- Файл для записи результата: $REVIEW_RESULT_FILE

## Порядок действий

1. Прочитай $PENDING_TASKS_FILE чтобы узнать task_id
2. Прочитай $TASKS_PATH чтобы найти описание задачи
3. Прочитай схему автовыбора: `~/.config/kilo/shared/review-selection.md`
4. Определи тип задачи по описанию
5. Загрузи нужные skills через `skill name="review-XXX"`
6. Проверь изменённые файлы (git diff HEAD~1)
7. Запусти `dotnet build` и `dotnet test` если применимо

## Формат результата

Создай файл $REVIEW_RESULT_FILE со следующим содержимым:

```markdown
---
decision: APPROVED
task_id: T001
reviewers:
  - review-security
  - review-architect-backend
verdicts:
  review-security: APPROVED
  review-architect-backend: APPROVED
high_issues: 0
medium_issues: 2
low_issues: 3
---

# Review Results

## Task: T001 - Task Name

### review-security
| Severity | File | Line | Problem | Suggestion |
|----------|------|------|---------|------------|
| MEDIUM | file.cs | 42 | Проблема | Решение |

**Verdict:** APPROVED

### review-architect-backend
| Severity | File | Line | Problem | Suggestion |
|----------|------|------|---------|------------|
| LOW | file.cs | 10 | Проблема | Решение |

**Verdict:** APPROVED

## Decision: APPROVED
```

При REJECTED добавь секцию:

```markdown
## Fix Required

1. **[HIGH]** Удалить захардкоженный пароль из config.json — вынести в переменную окружения
2. **[MEDIUM]** Добавить валидацию входных данных
```

ВАЖНО:
- Файл должен начинаться с YAML frontmatter между линиями `---`
- Поле `decision` должно быть `APPROVED` или `REJECTED`
- Поле `task_id` должно соответствовать задаче из $PENDING_TASKS_FILE
- При REJECTED обязательно добавь секцию `## Fix Required` с конкретными действиями
- Используй atomic write: пиши в temp файл, затем переименуй в $REVIEW_RESULT_FILE
```

---

### Task 7: Update ralph-iterate.md prompt

**File:** `ralph-loop/prompts/ralph-iterate.md`

**Change rejection handling section (lines 7-10):**

```markdown
Before starting:
1. Read the task file at $TASKS_PATH
2. **If $REVIEW_RESULT_FILE exists with REJECTED decision**: 
   - Read it to understand previous review rejection
   - Fix the SAME task that was rejected
   - DO NOT move to the next task
```

**Add to the list of variables (around line 17):**

```markdown
After completing the task, create file "$PENDING_TASKS_FILE":

Note: $REVIEW_RESULT_FILE is the path where review coordinator will write the result.
```

---

### Task 8: Add migration helper

**File:** `ralph-loop/scripts/ralph_loop.sh`

**Add function before main():**

```bash
migrate_old_files() {
    local migrated=0
    
    # Old files in PROJECT_ROOT that should be in FEATURE_DIR
    local old_files=(
        ".ralph_state.json"
        ".ralph_loop.log"
        ".ralph_pending_tasks.json"
        ".ralph_rejection_context.md"
        ".ralph_review_results.md"
        ".ralph_status_cache"
        ".ralph_frontmatter_cache"
    )
    
    for old_file in "${old_files[@]}"; do
        local old_path="${PROJECT_ROOT}/${old_file}"
        local new_path="${FEATURE_DIR}/${old_file}"
        
        if [[ -f "$old_path" ]] && [[ ! -f "$new_path" ]]; then
            print_status "info" "Migrating old file: $old_file → $FEATURE_DIR/"
            mv "$old_path" "$new_path" 2>/dev/null && ((migrated++))
        fi
    done
    
    # Remove files that are no longer needed
    rm -f "${PROJECT_ROOT}/.ralph_rejection_context.md" 2>/dev/null
    rm -f "${PROJECT_ROOT}/.ralph_review_results.md" 2>/dev/null
    
    if [[ $migrated -gt 0 ]]; then
        print_status "success" "Migrated $migrated file(s) to new format"
    fi
}
```

**Call migrate_old_files() after FEATURE_DIR is defined in main():**

```bash
# After line ~618
local FEATURE_DIR=$(dirname "$TASKS_PATH")
migrate_old_files
```

---

### Task 9: Update cleanup on task completion

**File:** `ralph-loop/scripts/ralph_loop.sh`

**Find and update the cleanup section (around line 842-843):**

```bash
# After task approved, clean up
rm -f "$PENDING_TASKS_FILE"

# Keep .ralph_review_result.md for next iteration reference (if REJECTED)
# Remove only if APPROVED
if [[ "$decision" == "APPROVED" ]]; then
    rm -f "$REVIEW_RESULT_FILE"
fi
```

---

### Task 10: Update symlink prompt paths

**File:** `.kilo/prompts/ralph-review.md`

**Verify symlink points to correct location:**

```bash
ls -la .kilo/prompts/ralph-review.md
# Should show: ralph-review.md -> ../../ralph-loop/prompts/ralph-review.md
```

If broken, recreate:

```bash
rm .kilo/prompts/ralph-review.md
ln -s ../../ralph-loop/prompts/ralph-review.md .kilo/prompts/ralph-review.md
```

---

## File Structure After Changes

```
$FEATURE_DIR/
├── tasks.md                        # Task index
├── tasks/                          # Task files
│   ├── T001.md
│   └── T002.md
├── .ralph_state.json               # State machine
├── .ralph_loop.log                 # Execution log
├── .ralph_pending_tasks.json       # Current task pending review
├── .ralph_review_result.md         # Review result (APPROVED or REJECTED)
└── .escalation_handoff.md          # Created on blocking issues
```

---

## Validation Steps

After implementation, validate:

1. **Clean run:** Start Ralph Loop on fresh feature
   - All files created in `$FEATURE_DIR/`
   - YAML frontmatter parsed correctly
   - Task completes after APPROVED

2. **Rejection flow:** Task with intentional issue
   - Review coordinator creates `.ralph_review_result.md` with REJECTED
   - Implementer reads file on next iteration
   - Fixes applied, review passes

3. **Error handling:** Simulate review coordinator failure
   - No file created after review
   - Retry triggered
   - After 2 retries: escalation created

4. **Migration:** Run on feature with old files in `$PROJECT_ROOT/`
   - Files migrated to `$FEATURE_DIR/`
   - No duplicate files
   - Loop continues normally

---

## Risks

| Risk | Mitigation |
|------|------------|
| Breaking existing features | Migration helper moves old files |
| YAML parsing fails | Fallback error message, manual inspection |
| Review coordinator doesn't write file | Retry + escalation |
| Parallel Ralph Loop instances | Each has own `$FEATURE_DIR` |

---

## Open Questions

None. All decisions finalized.
