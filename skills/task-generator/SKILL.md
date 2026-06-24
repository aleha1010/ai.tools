# Skill: task-generator

## Purpose

Генерирует tasks.md и файлы задач из plan.md для Ralph Loop. Работает интеллектуально без bash-скриптов.

## Вход

- `plan.md` — архитектура фичи с задачами в формате `### {ID}: Название`
- `.escalation_handoff.md` — (опционально) escalation файл для создания fix-задач

## Выход

- `tasks.md` — индекс задач в порядке выполнения
- `tasks/{ID}.md` — спецификации задач с YAML frontmatter

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

### AUTH-001: Setup authentication

Description.

Dependencies: T001, T002

### FIX-042: Fix login bug

Description.

Dependencies: AUTH-001
```

**Важно:** Формат task_id гибкий — поддерживаются T001, AUTH-001, FIX-042, HOTFIX-007 и т.д.

## Workflow

### Шаг 1: Прочитать plan.md

Найти все задачи по pattern: `^###\s+([A-Z0-9-]+):\s+(.+)$`

Для каждой задачи извлечь:
- `id` — task ID (например, T001, AUTH-001, FIX-042)
- `title` — название задачи
- `dependencies` — список зависимостей (если указаны)

### Шаг 2: Создать файлы задач

Для каждой задачи создать `tasks/{ID}.md`:

```yaml
---
id: {ID}
dependencies: [{DEPS}]
---
# {ID}: {Title}

## Context

[Extract context from plan.md — paragraphs under task header until next task or Dependencies line]

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

### Шаг 3: Создать tasks.md (индекс)

```markdown
# Tasks

- [ ] {ID1}: {Title1}
- [ ] {ID2}: {Title2}
- [ ] {ID3}: {Title3}
```

Порядок определяется порядком в plan.md. Ralph Loop сам определит порядок выполнения на основе dependencies.

### Шаг 4: Обработать escalation (если есть)

Если существует `.escalation_handoff.md`:

1. Прочитать escalation файл
2. Проанализировать проблему и контекст
3. Создать fix-задачу (например, FIX-001)
4. Добавить в tasks.md
5. Создать `tasks/FIX-001.md`
6. **Удалить** `.escalation_handoff.md`
7. Log: "Escalation processed and removed"

## Dependencies Format

Dependencies указываются в plan.md:

```markdown
### T002: Second task

Description.

Dependencies: T001
```

```markdown
### T003: Third task

Description.

Dependencies: T001, T002
```

```markdown
### AUTH-001: Auth setup

Description.

Dependencies: none
```

## Task ID Format

**Любой формат из plan.md валиден:**

- `T001`, `T042` — стандартные задачи
- `AUTH-001`, `AUTH-002` — задачи аутентификации
- `FIX-001`, `FIX-042` — багфиксы
- `HOTFIX-007` — хотфиксы
- `DB-001` — задачи базы данных

Формат task_id определяется планом. Валидация формата не требуется.

## Пример полного workflow

**Input (plan.md):**
```markdown
# User Authentication

## Architecture

### AUTH-001: Setup auth module

Create auth module with JWT support.

Dependencies: none

### AUTH-002: Add login endpoint

Implement /api/login endpoint.

Dependencies: AUTH-001

### AUTH-003: Add logout endpoint

Implement /api/logout endpoint.

Dependencies: AUTH-001
```

**Output 1 (tasks.md):**
```markdown
# Tasks

- [ ] AUTH-001: Setup auth module
- [ ] AUTH-002: Add login endpoint
- [ ] AUTH-003: Add logout endpoint
```

**Output 2 (tasks/AUTH-001.md):**
```yaml
---
id: AUTH-001
dependencies: []
---
# AUTH-001: Setup auth module

## Context

Create auth module with JWT support.

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
```

**Output 3 (tasks/AUTH-002.md):**
```yaml
---
id: AUTH-002
dependencies: [AUTH-001]
---
# AUTH-002: Add login endpoint

## Context

Implement /api/login endpoint.

## Test Specification (RED Phase)
...
```

## Интеграция с Ralph Loop

1. Planning Agent создаёт `plan.md` с задачами
2. Planning Agent вызывает task-generator skill
3. Skill создаёт `tasks.md` и файлы задач
4. Planning Agent заполняет спецификации тестов и реализации
5. Запускается `ralph_loop.sh --tasks-path features/001-auth/tasks.md`

## Escalation Processing

**Когда создавать FIX-задачи:**

Если `.escalation_handoff.md` существует:

1. Прочитать проблему из escalation
2. Определить ID для fix-задачи (например, FIX-001, FIX-002)
3. Создать файл задачи с описанием проблемы как Context
4. Добавить в tasks.md
5. Удалить `.escalation_handoff.md`

**Пример FIX-задачи:**

```yaml
---
id: FIX-001
dependencies: []
---
# FIX-001: Fix authentication bypass vulnerability

## Context

Escalation detected: Authentication can be bypassed by manipulating JWT token.

**Severity:** HIGH
**Component:** auth-module
**Discovered by:** review-security agent

## Test Specification (RED Phase)

### Test Cases
| ID | Scenario | Given | When | Then | Type |
|----|----------|-------|------|------|------|
| T1 | Auth bypass blocked | manipulated JWT | call API | returns 401 | integration |

## Implementation Specification (GREEN Phase)

Add JWT signature validation to auth middleware.
```

## Примечания

- Skill работает напрямую с файлами, без bash-скриптов
- Dependencies извлекаются из plan.md автоматически
- Escalation файл удаляется после обработки
- Формат task_id гибкий — любой ID из plan.md валиден
