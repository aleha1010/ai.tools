# Plan: Standardize Escalation File Location

**Problem**: Escalation file created in project root (`.escalation_handoff.md`) but Ralph Loop expects it in feature directory (`features/TEST-integration/.escalation_handoff.md`).

**Goal**: Standardize location to feature directory with robust detection.

---

## Changes

### 1. ralph_loop.sh - Add $FEATURE_DIR to prompt

**File**: `ralph-loop/scripts/ralph_loop.sh`

**Lines**: 678-683

**Before**:
```bash
local safe_task_path=$(printf '%s' "$TASK_FILE_PATH" | sed 's/[&/\]/\\&/g')
local safe_pending_path=$(printf '%s' "$PENDING_TASKS_FILE" | sed 's/[&/\]/\\&/g')

local PROMPT=$(sed "s|\$TASKS_PATH|$safe_task_path|g" "$PROMPT_FILE")
PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$safe_pending_path|g" <<< "$PROMPT")
```

**After**:
```bash
local safe_task_path=$(printf '%s' "$TASK_FILE_PATH" | sed 's/[&/\]/\\&/g')
local safe_pending_path=$(printf '%s' "$PENDING_TASKS_FILE" | sed 's/[&/\]/\\&/g')
local safe_feature_dir=$(printf '%s' "$FEATURE_DIR" | sed 's/[&/\]/\\&/g')

local PROMPT=$(sed "s|\$TASKS_PATH|$safe_task_path|g" "$PROMPT_FILE")
PROMPT=$(sed "s|\$PENDING_TASKS_FILE|$safe_pending_path|g" <<< "$PROMPT")
PROMPT=$(sed "s|\$FEATURE_DIR|$safe_feature_dir|g" <<< "$PROMPT")
```

---

### 2. ralph-iterate.md - Update escalation instructions

**File**: `ralph-loop/prompts/ralph-iterate.md`

**Lines**: 45-81

**Before**:
```markdown
1. Создай файл `.escalation_handoff.md` в директории фичи с содержимым:
```

**After**:
```markdown
1. Создай файл `.escalation_handoff.md` в директории фичи:
   ```bash
   cat > ${FEATURE_DIR}/.escalation_handoff.md << 'EOF'
   # Escalation Handoff

   **Task ID:** TXXX
   **Timestamp:** 2026-06-24T10:21:41+05:00
   **Severity:** BLOCKER | WARNING

   ## Обнаруженная проблема

   [Описание сложности, не описанной в плане]

   ## Пострадавшие задачи

   - **T001** (выполнена) — требует изменений
   - **T002** (текущая) — заблокирована

   ## Контекст

   - Что пытался сделать
   - Какие шаги уже выполнены
   - Текущее состояние файлов

   ## Варианты решения

   1. **Вариант A** — описание
      - Плюсы: ...
      - Минусы: ...

   ## Требуемые решения от Planning Agent

   - [ ] Создать fix-задачи для T001
   - [ ] Обновить dependencies для T002
   EOF
   ```
```

---

### 3. ralph_loop.sh - Add fallback detection

**File**: `ralph-loop/scripts/ralph_loop.sh`

**Lines**: 690-710

**Before**:
```bash
local escalation_file="${FEATURE_DIR}/.escalation_handoff.md"
if [[ -f "$escalation_file" ]]; then
```

**After**:
```bash
local escalation_file="${FEATURE_DIR}/.escalation_handoff.md"
local escalation_file_alt="${PROJECT_ROOT}/.escalation_handoff.md"

# Standard location: feature directory
# Fallback: project root (for backward compatibility)
if [[ -f "$escalation_file_alt" ]] && [[ ! -f "$escalation_file" ]]; then
    print_status "warning" "Escalation file in project root. Standard location: ${FEATURE_DIR}/.escalation_handoff.md"
    escalation_file="$escalation_file_alt"
fi

if [[ -f "$escalation_file" ]]; then
```

---

## Testing

After changes:

1. Run T005 scenario
2. Verify:
   - Kilo creates file in `${FEATURE_DIR}/.escalation_handoff.md`
   - Ralph Loop detects it correctly
   - State transitions to ESCALATION
   - Clear user notification

## Rollback

If issues:
1. Revert changes to ralph_loop.sh (lines 678-683, 690-710)
2. Revert changes to ralph-iterate.md (lines 45-81)
3. Escalation files will work in project root only

---

## Notes

- **Standard location**: `${FEATURE_DIR}/.escalation_handoff.md`
- **Fallback location**: `${PROJECT_ROOT}/.escalation_handoff.md` (backward compatibility)
- **Priority**: Feature directory > Project root
- **Warning**: If file found in fallback location, user notified about standard location
