# Skill: task-generator

## Purpose

Генерирует tasks.md и файлы задач из plan.md для Ralph Loop.

## Команда

```bash
./ralph-loop/scripts/generate-tasks.sh --plan-path features/001-auth/plan.md
```

## Вход

- `features/001-auth/plan.md` — архитектура фичи с задачами в формате `### T001: Название`

## Выход

- `features/001-auth/tasks.md` — индекс задач в порядке выполнения
- `features/001-auth/tasks/T001.md`, `T002.md`, ... — спецификации задач

## Формат plan.md

```markdown
# Feature Name

## Architecture

### T001: First task

Description of the task.

Dependencies: none

### T002: Second task

Description.

Dependencies: T001

### T003: Third task

Description.

Dependencies: T001, T002
```

## Формат tasks.md

```markdown
# Tasks

- [ ] T001: First task
- [ ] T002: Second task
- [ ] T003: Third task
```

## Формат файла задачи (tasks/T001.md)

```yaml
---
id: T001
dependencies: []
---
# T001: First task

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
```yaml
valid_input:
  param1: "example_value"
```

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
```

## Workflow

1. Planning Agent создаёт `plan.md` с задачами
2. Запускается `generate-tasks.sh --plan-path features/001-auth/plan.md`
3. Скрипт создаёт `tasks.md` и файлы задач
4. Planning Agent заполняет контекст и спецификации в файлах задач
5. Запускается `ralph_loop.sh --tasks-path features/001-auth/tasks.md`

## Валидация

- Все task IDs должны соответствовать паттерну `T[0-9]+`
- Dependencies должны ссылаться на существующие задачи
- Циклические зависимости должны отсутствовать

## Интеграция с Planning Agent

Planning Agent должен:
1. Создавать plan.md с задачами в правильном формате
2. Запускать generate-tasks.sh
3. Заполнять спецификации тестов и реализации в файлах задач
4. Проверять dependencies на корректность
