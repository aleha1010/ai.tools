# Integration Test Plan: Ralph Loop v2.0

**Goal**: Comprehensive integration testing of Ralph Loop orchestration with real Kilo CLI execution.

**Created**: 2026-06-24
**Status**: READY FOR TASK GENERATION
**Review Status**: APPROVED (review-analyst)

---

## DoR (Definition of Ready)

**Критерии готовности плана к реализации:**

### Обязательные критерии (должны быть выполнены ВСЕ)
- [x] **Чёткая постановка задачи** — Цель определена: интеграционное тестирование Ralph Loop v2.0
- [x] **Архитектурное решение согласовано** — Подход: тестовые задачи во временной директории с реальным Kilo CLI
- [x] **Риски идентифицированы** — Нет критических рисков, изоляция через mktemp
- [x] **Зависимости выявлены** — Требуется task-generator skill, kilo CLI, jq, git
- [x] **Критерии приёмки определены** — Все 9 сценариев проходят валидацию
- [x] **Ресурсы определены** — Временная директория, время выполнения ~10-15 минут
- [x] **Rollback план существует** — Удаление временной директории после тестов

### Блокирующие вопросы

| Вопрос | Статус | Ответ |
|--------|--------|-------|
| Формат совместим с task-generator? | ✅ | Да, добавлены Dependencies: строки |
| Задачи исполняемы Kilo? | ✅ | Да, содержат чёткие инструкции |
| Нет циклических зависимостей? | ✅ | Проверено: T001→T002, T003→T004 |

**Вердикт DoR:** ✅ READY

---

## DoD (Definition of Done)

**Критерии завершения задачи:**

### Функциональные критерии
- [ ] **Все сценарии выполнены** — 9 тестовых сценариев запущены и проверены
- [ ] **State machine валидна** — Все переходы состояний корректны

### Качество
- [ ] **Валидация файлов** — Все .ralph_*.json/md файлы корректны
- [ ] **Dependencies logic** — Зависимости проверяются правильно
- [ ] **Escalation handling** — Escalation обрабатывается корректно

### Тестирование
- [ ] **Happy path** — T001 прошёл успешно
- [ ] **Review rejection** — T002 retry работает
- [ ] **Dependencies** — T003→T004 порядок соблюдён
- [ ] **Escalation** — T005 создаёт handoff
- [ ] **Circuit breaker** — T006 останавливает после 3 failures
- [ ] **Review failures** — T007 останавливает после 2 rejections
- [ ] **All blocked** — T008 корректно обрабатывает blocked state
- [ ] **Error handling** — T009 обрабатывает Kilo ошибки

**Вердикт DoD:** ❌ NOT DONE (pending execution)

---

## Test Environment Setup

**Location**: Temporary directory (mktemp -d)

**Structure**:
```
features/TEST-integration/
├── plan.md                    # This file (reference)
├── tasks.md                   # Task index with dependencies
└── tasks/
    ├── T001.md                # Happy path task
    ├── T002.md                # Review rejection scenario
    ├── T003.md                # Dependency target (will be completed first)
    ├── T004.md                # Dependency dependent (blocked until T003 done)
    ├── T005.md                # Escalation scenario
    ├── T006.md                # Circuit breaker trigger
    ├── T007.md                # Review failures limit
    └── T008.md                # All blocked scenario
```

**Generated Files**:
- `.ralph_state.json` - State machine tracking
- `.ralph_loop.log` - Execution log
- `.ralph_pending_tasks.json` - Current task status
- `.ralph_rejection_context.md` - Review rejection details
- `.ralph_review_results.md` - Review results

---

## Test Scenarios (Tasks)

### T001: Happy Path - Successful Execution

Dependencies: none

**Objective**: Verify complete happy path cycle.

**Setup**:
- Create simple file creation task
- Review should APPROVE (minimal code, no issues)

**Expected Flow**:
1. Ralph Loop starts, state: IDLE
2. Detects T001 as next executable (no dependencies)
3. State: IMPLEMENTING
4. Kilo executes T001, creates pending file
5. State: REVIEWING
6. Review coordinator runs 5 reviewers
7. All reviewers APPROVE
8. State: COMMITTING (skip actual commit)
9. Task marked [x] in tasks.md
10. State: IDLE

**Validation**:
- [ ] `.ralph_state.json` transitions: IDLE → IMPLEMENTING → REVIEWING → COMMITTING → IDLE
- [ ] `.ralph_pending_tasks.json` created with task_id: "T001"
- [ ] tasks.md shows `- [x] T001` after execution
- [ ] No `.ralph_rejection_context.md` created
- [ ] State machine version tracking works
- [ ] State file contains valid JSON with: state, iteration, current_task, timestamp, pid

**Success Criteria**:
- Task completed without errors
- All state transitions logged
- Files created as expected

---

### T002: Review Rejection + Retry

Dependencies: T001

**Objective**: Verify rejection handling and retry mechanism.

**Setup**:
- Create task with intentional issues (security vulnerability)
- First review: REJECTED (SQL injection simulation)
- Second iteration: Fix issues, second review: APPROVED

**Expected Flow - Iteration 1**:
1. State: IDLE → IMPLEMENTING (T002)
2. Kilo creates vulnerable code
3. State: REVIEWING
4. review-security detects SQL injection → REJECTED
5. State: REJECTED
6. `.ralph_rejection_context.md` created with details
7. Task remains `- [ ] T002` (NOT marked complete)

**Expected Flow - Iteration 2**:
1. Kilo reads `.ralph_rejection_context.md`
2. Fixes the vulnerability
3. Creates new `.ralph_pending_tasks.json` with same task_id: "T002"
4. State: REVIEWING
5. All reviewers APPROVE
6. Task marked [x]

**Validation**:
- [ ] `.ralph_rejection_context.md` created after first review
- [ ] Rejection context contains:
  - Task ID: T002
  - Timestamp
  - Reviewer: review-security
  - Issue description
  - FIX REQUIRED section with numbered items
- [ ] Second iteration reads rejection context
- [ ] Task not marked complete until APPROVED
- [ ] State machine tracks REJECTED state
- [ ] State transitions: IDLE → IMPLEMENTING → REVIEWING → REJECTED → IMPLEMENTING → REVIEWING → COMMITTING → IDLE
- [ ] `review_failures` counter resets to 0 after successful APPROVED (line 806 in ralph_loop.sh)

**Success Criteria**:
- Rejection detected and logged
- Retry mechanism works
- Task eventually approved

---

### T003: Dependency Target (No Dependencies)

Dependencies: none

**Objective**: Task with no dependencies, serves as dependency for T004.

**Setup**:
- Simple task (create config file)
- dependencies: [] (empty)

**Expected Flow**:
1. T003 has no dependencies → immediately executable
2. Execute, review, approve
3. Mark [x]

**Validation**:
- [ ] Task executes immediately
- [ ] Status cache shows T003=x after completion

**Success Criteria**:
- Task completes before T004

---

### T004: Dependency Dependent (Blocked Until T003)

Dependencies: T003

**Objective**: Verify dependencies checking logic.

**Setup**:
- YAML frontmatter:
  ```yaml
  ---
  id: T004
  dependencies: [T003]
  ---
  ```
- T003 initially incomplete (space in [ ])

**Expected Flow - First Attempt**:
1. Ralph Loop checks T004 dependencies
2. T003 status: incomplete (space in [ ])
3. T004 BLOCKED
4. Ralph Loop processes T003 first

**Expected Flow - After T003 Complete**:
1. T003 marked [x]
2. Status cache rebuilt
3. T004 dependencies check: T003=x → PASS
4. T004 becomes executable
5. Execute, review, approve

**Validation**:
- [ ] T004 not selected while T003 incomplete
- [ ] `check_dependencies()` returns false initially
- [ ] `get_next_executable_task()` skips T004
- [ ] After T003 done, T004 selected
- [ ] Frontmatter cache used for performance

**Success Criteria**:
- Dependencies enforced correctly
- Tasks execute in correct order

---

### T005: Escalation Protocol

Dependencies: none

**Objective**: Verify escalation handling when agent encounters blocker.

**Setup**:
- Task with incomplete specification
- Agent creates `.escalation_handoff.md`

**Expected Flow**:
1. State: IMPLEMENTING (T005)
2. Kilo agent runs and encounters unresolvable issue
3. Agent creates `.escalation_handoff.md` with:
   - Task ID: T005
   - Timestamp
   - Severity: BLOCKER
   - Description of problem
   - Context (what was attempted)
   - Options for resolution
   - Required decisions from Planning Agent
4. Agent does NOT create `.ralph_pending_tasks.json`
5. Agent exits (return code 0)
6. Ralph Loop checks for escalation file after Kilo completes (lines 690-710)
7. Escalation file detected
8. State: ESCALATION (via save_state)
9. Ralph Loop stops with clear message
10. Provides next steps for user

**Validation**:
- [ ] `.escalation_handoff.md` created in feature directory
- [ ] File contains required sections:
  - Task ID
  - Timestamp
  - Severity
  - Problem description
  - Context
  - Options
  - Required decisions
- [ ] Ralph Loop exits with status: ESCALATION
- [ ] User notification contains:
  - Escalation file path
  - Next steps
  - How to resume

**Success Criteria**:
- Escalation detected
- Handoff document created
- Clear user guidance

---

### T006: Circuit Breaker (3 Consecutive Failures)

Dependencies: none

**Objective**: Verify circuit breaker stops after 3 failures.

**Setup**:
- Task designed to fail (invalid instructions)
- Mock Kilo to return exit code 1

**Expected Flow**:
1. Iteration 1: T006 fails → consecutive_failures=1
   - Backoff: 2^1 = 2s
2. Iteration 2: T006 fails → consecutive_failures=2
   - Backoff: 2^2 = 4s
3. Iteration 3: T006 fails → consecutive_failures=3
   - Backoff: 2^3 = 8s (max 60s)
4. consecutive_failures >= MAX_CONSECUTIVE_FAILURES (3)
5. Circuit breaker triggers
6. State: FAILED
7. Exit with error message

**Validation**:
- [ ] `consecutive_failures` counter increments correctly
- [ ] Exponential backoff: 2s, 4s, 8s (formula: 2^n, max 60s)
- [ ] State transitions: IDLE → IMPLEMENTING → FAILED (for each attempt)
- [ ] Exit code: 1
- [ ] Error message: "Circuit breaker сработал"
- [ ] Summary shows: 0 tasks completed, status: CIRCUIT_BREAKER
- [ ] Total attempts >= 3

**Success Criteria**:
- Circuit breaker activates at 3 failures
- Exponential backoff applied
- Clear error message

---

### T007: Review Failures Limit (2 Consecutive)

Dependencies: none

**Objective**: Verify review failure tolerance (max 2).

**Setup**:
- Task with persistent issues
- Review consistently REJECTS

**Expected Flow**:
1. Iteration 1: Review REJECTED → review_failures=1
2. Agent fixes (incompletely)
3. Iteration 2: Review REJECTED → review_failures=2
4. Limit reached
5. State: REJECTED
6. Exit with error

**Validation**:
- [ ] `review_failures` counter increments
- [ ] After 2 rejections, loop stops
- [ ] `.ralph_rejection_context.md` created each time with:
  - Task ID
  - Timestamp
  - Review results section
  - FIX REQUIRED section
- [ ] Exit code: 1
- [ ] Error message: "Слишком много неудач review"
- [ ] Summary shows: review_failures: 2
- [ ] State transitions: IDLE → IMPLEMENTING → REVIEWING → REJECTED (x2)

**Success Criteria**:
- Review failures tracked
- Limit enforced
- User informed

---

### T008: All Tasks Blocked

Dependencies: none

**Objective**: Verify graceful handling when all tasks are blocked.

**Setup**:
- tasks.md with tasks all having unmet dependencies
- Example: T010 depends on T011, T011 depends on T010 (circular)
- Or: all depend on non-existent T999

**Expected Flow**:
1. Ralph Loop scans tasks
2. No task has all dependencies met
3. `get_next_executable_task()` returns empty
4. Incomplete tasks remain
5. State: ALL_BLOCKED
6. Exit with error

**Validation**:
- [ ] `get_next_executable_task()` returns ""
- [ ] Incomplete task count > 0
- [ ] Error message: "Все оставшиеся задачи заблокированы"
- [ ] Exit code: 1
- [ ] Summary shows: ALL_BLOCKED
- [ ] Note: ALL_BLOCKED is an exit status, not a state machine state

**Success Criteria**:
- Blocked situation detected
- Clear error message
- No infinite loop

---

### T009: Kilo CLI Error

Dependencies: none

**Objective**: Verify handling of Kilo CLI failures.

**Setup**:
- Kilo CLI not in PATH or returns error
- Or: Kilo session error

**Expected Flow**:
1. State: IMPLEMENTING
2. Kilo command fails (exit code != 0)
3. Error detected
4. State: FAILED
5. Consecutive failures increment
6. Eventually circuit breaker (or single error handling)

**Validation**:
- [ ] Kilo exit code captured
- [ ] Error message logged
- [ ] State machine transitions to FAILED
- [ ] Backoff applied
- [ ] User informed

**Success Criteria**:
- Errors caught
- No unhandled exceptions
- Graceful degradation

---

## Test Execution Strategy

### Phase 1: Environment Preparation
1. Create temporary directory
2. Initialize git repo
3. Create feature structure
4. Create task files with YAML frontmatter

### Phase 2: Task Generation
1. Use task-generator skill to create tasks from this plan
2. Generate: tasks.md + tasks/T00X.md files
3. Each task file will have YAML frontmatter:
   ```yaml
   ---
   id: T004
   dependencies: [T003]
   ---
   # Task content...
   ```

### Phase 3: Sequential Testing
1. Run each scenario in order
2. Validate state after each scenario
3. Collect metrics

### Phase 4: Validation
1. Check all generated files
2. Verify state machine transitions
3. Confirm error handling

---

## Validation Checklist

### State Machine
- [ ] All states visited: IDLE, IMPLEMENTING, REVIEWING, COMMITTING, REJECTED, FAILED, ESCALATION, COMPLETE
- [ ] Note: ALL_BLOCKED is an exit status, not a state machine state
- [ ] State transitions logged in `.ralph_state.json`
- [ ] PID tracking works
- [ ] Timestamp accuracy
- [ ] State file format: `{"state": "...", "iteration": N, "current_task": "...", "timestamp": "...", "pid": N}`

### Output Files
- [ ] `.ralph_state.json` valid JSON
- [ ] `.ralph_loop.log` contains all phases
- [ ] `.ralph_pending_tasks.json` has correct task_id
- [ ] `.ralph_rejection_context.md` formatted correctly
- [ ] `.ralph_review_results.md` contains all reviewers

### Dependencies Logic
- [ ] Status cache built correctly
- [ ] Frontmatter parsed
- [ ] Dependencies checked before task execution
- [ ] Blocked tasks skipped
- [ ] Cache performance acceptable

### Error Handling
- [ ] Circuit breaker works (3 failures)
- [ ] Review failures limit (2 rejections)
- [ ] Escalation detected
- [ ] Kilo errors handled
- [ ] Blocked tasks detected

---

## Expected Test Results

| Scenario | Expected Status | Tasks Completed | State After |
|----------|----------------|-----------------|-------------|
| T001 | SUCCESS | 1 | IDLE |
| T002 | SUCCESS (after retry) | 1 | IDLE |
| T003 | SUCCESS | 1 | IDLE |
| T004 | SUCCESS (after T003) | 1 | IDLE |
| T005 | ESCALATION | 0 | ESCALATION |
| T006 | CIRCUIT_BREAKER | 0 | FAILED (after 3 attempts) |
| T007 | REVIEW_FAILURES | 0 | REJECTED |
| T008 | ALL_BLOCKED | 0 | IDLE (exit status: ALL_BLOCKED) |
| T009 | ERROR | 0 | FAILED |

---

## Post-Test Cleanup

After testing:
1. Remove test feature directory
2. Remove generated files (.ralph_*.json, .ralph_*.md)
3. Preserve logs for analysis
4. Document any failures

---

## Metrics to Collect

- Total execution time per scenario
- State transition count
- Review duration
- Backoff time applied
- Files created/modified
- Error messages clarity

---

## Notes

- **Commit excluded**: As requested, actual git commits will be skipped or mocked
- **Real Kilo CLI**: Tests will use actual Kilo CLI, not mocks
- **Isolation**: Each scenario runs in isolation with fresh state
- **Idempotency**: Tests can be run multiple times

---

## Next Steps

1. ✅ Plan created
2. ⏳ Use task-generator skill to create task files
3. ⏳ Run Ralph Loop with test feature
4. ⏳ Validate results
5. ⏳ Document findings
