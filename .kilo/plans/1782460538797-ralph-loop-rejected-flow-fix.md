# Plan: Ralph Loop REJECTED Flow Fix

**Date:** 2026-06-26
**Status:** APPROVED — Ready for Implementation
**Priority:** HIGH

---

## Executive Summary

Две критические проблемы в Ralph Loop:
1. **Переменная `$REVIEW_RESULT_FILE` не передаётся в prompt реализатора** — implementer не видит результаты review
2. **При REJECTED выбирается другая задача** — вместо исправления текущей

**Решение:** Добавить подстановку `$REVIEW_RESULT_FILE` и проверку REJECTED state при выборе задачи.

---

## Architecture Review

**Вердикт:** APPROVED

### Найденные проблемы (все исправлены)

| Severity | Section | Problem | Fix |
|----------|---------|---------|-----|
| 🔴 HIGH | Fix 2 | Task file удалён — проверка существования НЕ добавлена | ✅ Добавлена проверка `[[ -f "$task_file_to_check" ]]` |
| 🔴 HIGH | Edge Cases | State file corrupted — jq вернёт empty без валидации | ✅ Добавлена валидация `jq -e . "$STATE_FILE"` |
| 🟡 MEDIUM | Fix 1 | Дублирование escape-логики (`printf '%q'` vs `printf '%s' \| sed`) | ✅ Унифицировано: `printf '%s' \| sed 's/[&/\]/\\&/g'` |
| 🟡 MEDIUM | Validation | Integration test не проверяет содержимое `$REVIEW_RESULT_FILE` | ✅ Добавлена проверка в Validation |
| 🟡 MEDIUM | Test Suite | Тесты для REJECTED flow отсутствуют | ✅ Добавлено 4 теста в Task 3 |
| 🟢 LOW | DoD | Нет явного критерия сохранения `$REVIEW_RESULT_FILE` | ✅ Добавлен критерий в DoD |

---

## Solution Architecture

### Fix 1: Подстановка `$REVIEW_RESULT_FILE` в prompt

**Файл:** `ralph-loop/scripts/ralph_loop.sh`
**Строки:** 765-772

> **Note:** Используем `printf '%s' | sed` для consistency с `run_review_gate` (строки 457-463).

```bash
# ДО:
local safe_task_path=$(printf '%q' "$TASK_FILE_PATH")
local safe_pending_path=$(printf '%q' "$PENDING_TASKS_FILE")
local safe_feature_dir=$(printf '%q' "$FEATURE_DIR")

local PROMPT=$(sed "s|\$TASKS_PATH|$safe_task_path|g" "$PROMPT_FILE")
PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$safe_pending_path|g" <<< "$PROMPT")
PROMPT=$(sed "s|\$FEATURE_DIR|$safe_feature_dir|g" <<< "$PROMPT")

# ПОСЛЕ:
local safe_task_path=$(printf '%q' "$TASK_FILE_PATH")
local safe_pending_path=$(printf '%q' "$PENDING_TASKS_FILE")
local safe_feature_dir=$(printf '%q' "$FEATURE_DIR")
local safe_review_result=$(printf '%s' "$REVIEW_RESULT_FILE" | sed 's/[&/\]/\\&/g')  # NEW

local PROMPT=$(sed "s|\$TASKS_PATH|$safe_task_path|g" "$PROMPT_FILE")
PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$safe_pending_path|g" <<< "$PROMPT")
PROMPT=$(sed "s|\$FEATURE_DIR|$safe_feature_dir|g" <<< "$PROMPT")
PROMPT=$(sed "s|\$REVIEW_RESULT_FILE|$safe_review_result|g" <<< "$PROMPT")  # NEW
```

### Fix 2: Forced task selection при REJECTED

**Файл:** `ralph-loop/scripts/ralph_loop.sh`
**Строки:** 720-740

```bash
# ДО:
((total_attempts++))
print_header "$iteration" "$MAX_ITERATIONS"

local next_task=""

if [[ -d "$TASKS_DIR" ]]; then
    next_task=$(get_next_executable_task "$TASKS_PATH" "$TASKS_DIR" "$STATUS_CACHE_FILE")
    # ...
fi

# ПОСЛЕ:
((total_attempts++))
print_header "$iteration" "$MAX_ITERATIONS"

local next_task=""

# Check if previous iteration was REJECTED
if [[ -f "$STATE_FILE" ]]; then
    local prev_state=$(jq -r '.state // empty' "$STATE_FILE" 2>/dev/null)
    local prev_task=$(jq -r '.current_task // empty' "$STATE_FILE" 2>/dev/null)
    
    if [[ "$prev_state" == "REJECTED" && -n "$prev_task" ]]; then
        print_status "info" "Продолжение работы над отклонённой задачей: $prev_task"
        next_task="$prev_task"
    fi
fi

# Normal task selection if not REJECTED continuation
if [[ -z "$next_task" ]]; then
    if [[ -d "$TASKS_DIR" ]]; then
        next_task=$(get_next_executable_task "$TASKS_PATH" "$TASKS_DIR" "$STATUS_CACHE_FILE")
        # ... existing code
    else
        next_task=$(get_first_incomplete_task "$TASKS_PATH")
    fi
fi
```

---

## Implementation Tasks

### Task 1: Добавить подстановку $REVIEW_RESULT_FILE

**Файл:** `ralph-loop/scripts/ralph_loop.sh`

1. После строки 767 добавить:
   ```bash
   local safe_review_result=$(printf '%s' "$REVIEW_RESULT_FILE" | sed 's/[&/\]/\\&/g')
   ```

2. После строки 771 добавить:
   ```bash
   PROMPT=$(sed "s|\$REVIEW_RESULT_FILE|$safe_review_result|g" <<< "$PROMPT")
   ```

### Task 2: Добавить проверку REJECTED state

**Файл:** `ralph-loop/scripts/ralph_loop.sh`

1. После строки 722 (перед `local next_task=""`) добавить блок проверки state:
   ```bash
   # Check if previous iteration was REJECTED - continue with same task
   if [[ -f "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
       local prev_state=$(jq -r '.state // empty' "$STATE_FILE" 2>/dev/null)
       local prev_task=$(jq -r '.current_task // empty' "$STATE_FILE" 2>/dev/null)
       
       if [[ "$prev_state" == "REJECTED" && -n "$prev_task" ]]; then
           # Verify task file still exists before continuing
           local task_file_to_check=""
           if [[ -d "$TASKS_DIR" ]]; then
               task_file_to_check="${TASKS_DIR}/${prev_task}.md"
           else
               task_file_to_check="$TASKS_PATH"
           fi
           
           if [[ -f "$task_file_to_check" ]]; then
               print_status "info" "Продолжение работы над отклонённой задачей: $prev_task"
               next_task="$prev_task"
           else
               print_status "warning" "Task file для REJECTED задачи не найден: $task_file_to_check"
               print_status "info" "Fallback к нормальному выбору задачи"
           fi
       fi
   fi
   ```

2. Обернуть существующий код выбора задачи (строки 725-739) в условие:
   ```bash
   if [[ -z "$next_task" ]]; then
       # ... existing task selection code
   fi
   ```

### Task 3: Добавить тесты

**Файл:** `ralph-loop/tests/test_new_functions.sh`

Добавить в конец файла перед `main()`:

```bash
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
    
    # Simulate the substitution logic from ralph_loop.sh
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
    
    # Simulate state file with REJECTED
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
    
    # Simulate the logic from Fix 2
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
    
    # Simulate state file with REJECTED
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
    # T999.md NOT created - task file missing
    
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
    
    # next_task should be empty - fallback to normal selection
    if [[ -z "$next_task" ]]; then
        return 0
    else
        echo "Should fallback when task file missing, got: $next_task" >&2
        return 1
    fi
}

test_corrupted_state_file_fallback() {
    source_functions
    
    # Simulate corrupted state file
    local state_file="$TEST_TMP_DIR/.ralph_state.json"
    echo "{ invalid json }" > "$state_file"
    
    local next_task=""
    
    if [[ -f "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then
        # Should NOT enter this block
        next_task="SHOULD_NOT_BE_SET"
    fi
    
    if [[ -z "$next_task" ]]; then
        return 0
    else
        echo "Should fallback when state file corrupted" >&2
        return 1
    fi
}
```

И добавить вызовы тестов в `main()`:

```bash
run_test "review_result_file передаётся в prompt" test_review_result_file_passed_to_prompt
run_test "REJECTED task продолжается на следующей итерации" test_rejected_task_continued_on_next_iteration
run_test "Fallback при отсутствующем task file" test_rejected_task_missing_file_fallback
run_test "Fallback при повреждённом state file" test_corrupted_state_file_fallback
```

---

## Edge Cases

| Case | Handling |
|------|----------|
| Несколько REJECTED подряд | Счётчик `review_retries`, circuit breaker после `MAX_REVIEW_FAILURES` (уже реализовано) |
| REJECTED → APPROVED | Сброс `review_retries = 0`, удаление `REVIEW_RESULT_FILE` (уже реализовано) |
| Task file удалён | ✅ Добавлена проверка существования файла перед продолжением (Fix 2) |
| State file corrupted | ✅ Добавлена валидация JSON: `jq -e . "$STATE_FILE"` (Fix 2) |
| `$REVIEW_RESULT_FILE` не существует при REJECTED | Prompt содержит путь, implementer проверяет существование файла |
| `$REVIEW_RESULT_FILE` удалён между итерациями | Implementer увидит пустой файл, fallback к обычной реализации |

---

## Validation

После реализации выполнить:

1. **Unit tests:**
   ```bash
   ./ralph-loop/tests/test_new_functions.sh
   ```

2. **Integration test (T002):**
   ```bash
   ./ralph-loop/scripts/ralph_loop.sh --tasks-path .kilo/plans/tasks.md --no-commit --max-iterations 10
   ```
   
   Ожидаемое поведение:
   - Итерация N: T002 создан → review REJECTED
   - Итерация N+1: Лог показывает "Продолжение работы над отклонённой задачей: T002"
   - Итерация N+1: Implementer получает `$REVIEW_RESULT_FILE` с замечаниями review
   - Итерация N+1: T002 исправлен → review APPROVED → помечен как [x]

3. **Regression test (T001):**
   ```bash
   # После T002, проверить что T001 happy path не сломан
   ./ralph-loop/scripts/ralph_loop.sh --tasks-path .kilo/plans/tasks-T001-only.md --no-commit
   ```

---

## Risks

| Risk | Mitigation |
|------|------------|
| Regression в normal flow | Тест T001 должен проходить (happy path) |
| jq not available | Использовать `2>/dev/null` и проверять empty string |
| Infinite loop при REJECTED | Уже есть `MAX_REVIEW_FAILURES` и circuit breaker |

---

## Files Changed

| File | Lines | Change |
|------|-------|--------|
| `ralph-loop/scripts/ralph_loop.sh` | ~767, ~771, ~722 | Add `$REVIEW_RESULT_FILE` substitution, add REJECTED state check |
| `ralph-loop/tests/test_new_functions.sh` | end | Add 2 new tests |

---

## DoD (Definition of Done)

- [ ] Переменная `$REVIEW_RESULT_FILE` передаётся в prompt реализатора
- [ ] При REJECTED выбирается та же задача (не следующая)
- [ ] `$REVIEW_RESULT_FILE` сохраняется при REJECTED для следующей итерации
- [ ] Проверка существования task file при REJECTED continuation
- [ ] Валидация JSON state file перед чтением
- [ ] Unit tests проходят (включая 4 новых теста REJECTED flow)
- [ ] Integration test T002 проходит (REJECTED → retry → APPROVED)
- [ ] T001 happy path не сломан (regression test)
