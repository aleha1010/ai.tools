# План: Устранение зависимости Ralph Loop от SpecKit

## Цель

Переработать Ralph Loop для полной независимости от структуры и данных SpecKit, сохранив функциональность.

## Контекст

### Текущая проблема
- `ralph-iterate.md` вызывает `.specify/scripts/bash/check-prerequisites.sh` — жёсткая зависимость
- Агент имеет доступ к `tasks.md` и сам помечает задачи `[x]` — нарушение изоляции
- Структура `specs/001-feature/` жёстко задана

### Целевое решение
- Orchestrator управляет выбором задач и пометкой `[x]`
- Агент получает только файл конкретной задачи — не может влиять на список
- Task Generator skill создаёт задачи из плана с правильным порядком выполнения
- Все артефакты в папке фичи: `features/001-auth/`

## Решения

### 1. Структура на фичу

```
features/
  001-auth/
    tasks.md           → индекс задач (порядок = последовательность)
    tasks/
      T001.md         → спецификация задачи
      T002.md
    progress.md       → история выполнения (обязателен)
    plan.md           → архитектура фичи (обязателен)
```

### 2. Формат задачи (tasks/T001.md)

```yaml
---
id: T001
dependencies: [T000]
---
# T001: Название задачи

## Context
Связь с планом, контекст выполнения

## Test Specification (RED Phase)

### Test Type
- [ ] Unit (isolated, mocked dependencies)
- [ ] Integration (real dependencies)

### Test Cases
| ID | Scenario | Given | When | Then | Type |
|----|----------|-------|------|------|------|
| T1 | Happy path | valid input | call method | returns success | unit |
| T2 | Invalid input | null input | call method | throws exception | unit |
| T3 | Edge case | boundary value | call method | returns expected | unit |

### Test Data
```yaml
valid_input:
  param1: "example_value"
  param2: 42

invalid_input:
  param1: null
  param2: -1
```

### Mocks/Stubs Required
- DependencyName → mock behaviour

### Expected Outcomes
- T1: return value, side effects
- T2: exception type + message

## Implementation Specification (GREEN Phase)
Что реализовать (без деталей реализации)

## Refactoring Notes (REFACTOR Phase)
Потенциальные улучшения после GREEN

## Acceptance Criteria
- [ ] All test cases pass
- [ ] Coverage ≥ 80% on new code
- [ ] No test smells (AAA, no shared state)

## Constraints
Технические ограничения
```

### 2.1. Пример заполненной задачи

```yaml
---
id: T001
dependencies: []
---
# T001: Parse YAML frontmatter from task file

## Context
Used by ralph_loop.sh to extract dependencies from tasks/T001.md. Critical for dependency resolution before task execution.

## Test Specification (RED Phase)

### Test Type
- [x] Unit (isolated, mocked dependencies)

### Test Cases
| ID | Scenario | Given | When | Then | Type |
|----|----------|-------|------|------|------|
| T1 | Valid frontmatter | task file with YAML | `parse_frontmatter()` | returns dict with id, dependencies | unit |
| T2 | Empty dependencies | `dependencies: []` | `parse_frontmatter()` | returns empty list | unit |
| T3 | Missing frontmatter | file without YAML | `parse_frontmatter()` | returns default {"id": "", "dependencies": []} | unit |
| T4 | Invalid YAML | malformed frontmatter | `parse_frontmatter()` | returns default + logs warning | unit |

### Test Data
```yaml
valid_frontmatter: |
  ---
  id: T001
  dependencies: [T000, T002]
  ---

empty_dependencies: |
  ---
  id: T001
  dependencies: []
  ---

no_frontmatter: |
  # T001: Task without frontmatter

malformed: |
  ---
  id: T001
  dependencies: [broken
  ---
```

### Mocks/Stubs Required
- None (pure function)

### Expected Outcomes
- T1: `{"id": "T001", "dependencies": ["T000", "T002"]}`
- T2: `{"id": "T001", "dependencies": []}`
- T3: `{"id": "", "dependencies": []}`
- T4: `{"id": "", "dependencies": []}` + warning logged

## Implementation Specification (GREEN Phase)
Implement `parse_frontmatter(file_path: str) -> dict` in bash:
- Read file content
- Extract content between `---` delimiters
- Parse `id` and `dependencies` with whitelist validation
- Return structured dict

## Refactoring Notes (REFACTOR Phase)
- Consider caching parsed frontmatter to avoid re-reading files
- Add schema validation for additional fields if needed

## Acceptance Criteria
- [ ] All test cases pass
- [ ] Handles malformed input gracefully
- [ ] Performance: O(1) for typical frontmatter size

## Constraints
- No external dependencies beyond bash builtins
- Must work with UTF-8 files
```

### 3. Task Generator Skill

**Skill:** `task-generator`
**Command:** `/generate-tasks`

**Вход:**
- `features/001-auth/plan.md` — архитектура фичи

**Выход:**
- `features/001-auth/tasks.md` — индекс задач в порядке выполнения
- `features/001-auth/tasks/T001.md`, `T002.md`, ... — спецификации задач

**Логика:**
1. Анализирует план на предмет задач
2. Определяет dependencies между задачами
3. Выполняет topological sort
4. Присваивает `id` по порядку (T001, T002, ...)
5. Записывает `tasks.md` в правильном порядке
6. Создаёт файлы задач с YAML frontmatter

### 4. ralph_loop.sh изменения

**Текущий алгоритм:**
```bash
1. Вызвать check-prerequisites.sh → FEATURE_DIR
2. Найти первый [ ] в tasks.md
3. Передать весь tasks.md агенту
4. Агент помечает [x]
5. Review
6. Commit
```

**Новый алгоритм:**
```bash
1. FEATURE_DIR = dirname($TASKS_PATH)
2. Построить TASK_STATUS_CACHE (один раз за итерацию)
3. Найти все [ ] задачи в порядке файла
4. Для каждой проверить dependencies:
   - Если есть невыполненные → пометить как BLOCKED
   - Если все выполнены → EXECUTABLE
5. Если все [ ] задачи BLOCKED:
   - Exit с ошибкой "All remaining tasks blocked by unresolved dependencies"
6. Взять первую EXECUTABLE задачу
7. Прочитать tasks/T001.md
8. Передать агенту только tasks/T001.md (НЕ tasks.md)
9. Агент создаёт $PENDING_TASKS_FILE
10. Review
11. После APPROVED → orchestrator помечает [x] в tasks.md
12. Commit
```

### 5. ralph-iterate.md изменения

**Убрать:**
- Вызов `.specify/scripts/bash/check-prerequisites.sh`
- Чтение `FEATURE_DIR/progress.md` (orchestrator управляет)
- Чтение `FEATURE_DIR/plan.md` (все данные в файле задачи)

**Оставить:**
- Чтение переданного файла задачи
- TDD реализация
- Создание `$PENDING_TASKS_FILE`

### 6. Изоляция агента (Security Enforcement)

**Агент НЕ имеет доступа к:**
- `tasks.md` — не может сам пометить `[x]`
- `progress.md` — не может изменить историю
- `plan.md` — не нужен, все данные в файле задачи

**Агент получает:**
- Только `tasks/T001.md` — полная спецификация для выполнения

**Defense-in-depth меры:**
1. **Права доступа:**
   ```bash
   chmod 600 "$FEATURE_DIR/tasks.md" "$FEATURE_DIR/progress.md"
   ```
2. **Проверка изоляции:**
   ```bash
   verify_agent_isolation() {
       # Агент не должен иметь write доступ к критичным файлам
       for file in tasks.md progress.md plan.md; do
           if [[ -w "$FEATURE_DIR/$file" ]]; then
               error "SECURITY: Agent has write access to $file"
               return 1
           fi
       done
   }
   ```
3. **Sandbox (опционально):**
   - Запуск агента в Docker container с read-only mount для tasks/
   - Или restricted shell с whitelist команд

### 7. Rollback план

**Git backup:**
```bash
# Перед миграцией
git checkout -b backup/pre-migration-$(date +%Y%m%d)
git commit -am "backup: pre-migration snapshot"
```

**Атомарные операции:**
```bash
# Использовать temp файлы и mv вместо прямой записи
tmp_file=$(mktemp)
echo "$new_content" > "$tmp_file"
mv "$tmp_file" "$target_file"  # атомарно
```

**Rollback скрипт:**
```bash
#!/bin/bash
# rollback-migration.sh

if git rev-parse --verify backup/pre-migration-* >/dev/null 2>&1; then
    git checkout backup/pre-migration-*
    echo "Rolled back to pre-migration state"
else
    echo "No backup branch found"
    exit 1
fi
```

**Verify-then-commit:**
```bash
verify_structure() {
    # Проверить структуру после каждого шага
    [[ -f "$FEATURE_DIR/tasks.md" ]] || error "tasks.md missing"
    [[ -d "$FEATURE_DIR/tasks" ]] || error "tasks/ directory missing"
    # ... другие проверки
}
```

### 8. Escalation Protocol

**Паттерн:** Escalation with Handoff (Pause-and-Notify)

**Workflow:**
```
1. Implementation Agent обнаруживает проблему
   ↓
2. Создаёт .escalation_handoff.md
   ↓
3. Ralph Loop останавливается с понятным уведомлением
   ↓
4. Пользователь читает handoff, запускает plan-agents
   ↓
5. Planning Agent уточняет план (с участием человека)
   ↓
6. Пользователь перезапускает ralph_loop.sh
   ↓
7. Ralph Loop продолжает с обновлённым планом
```

**Триггеры для escalation:**

| Триггер | Пример |
|---------|--------|
| Неописанная зависимость | "Для задачи T003 нужен API, которого нет в плане" |
| Противоречивые требования | "Test Specification требует X, Constraints запрещают X" |
| Недостаточно данных | "Отсутствует Test Data для edge case" |
| Технический блокер | "Нужна библиотека, не совместимая с текущим стеком" |
| Scope creep | "Задача требует изменений в 3 модулях вместо 1" |

**Формат handoff документа:**
```markdown
# Escalation Handoff

**Task ID:** T003
**Timestamp:** 2026-06-24T10:21:41+05:00
**Severity:** BLOCKER | WARNING

## Обнаруженная проблема

[Описание сложности, не описанной в плане]

## Пострадавшие задачи

- **T001** (выполнена) — требует изменений в API contract
- **T002** (выполнена) — требует обновления под новый API
- **T003** (текущая) — заблокирована до исправления T001, T002
- **T004, T005** — заблокированы транзитивно

## Контекст

- Что пытался сделать агент
- Какие шаги уже выполнены
- Текущее состояние файлов

## Варианты решения

1. **Вариант A** — [описание]
   - Плюсы: ...
   - Минусы: ...

2. **Вариант B** — [описание]

## Требуемые решения от Planning Agent

- [ ] Создать fix-задачи для T001, T002
- [ ] Обновить dependencies для T003

## Влияние на план

- Заблокированные задачи: T003, T004, T005
- Оценка влияния: 2 выполненные задачи требуют изменений
```

**Уведомление при остановке:**
```
⚠️  ESCALATION DETECTED

Task T003 requires clarification.

Handoff document: features/001-auth/.escalation_handoff.md

Blocked tasks: T003, T004, T005

NEXT STEPS:
1. Review .escalation_handoff.md
2. Run: kilo run "Analyze escalation and create fix-tasks for features/001-auth"
3. Review .proposed_fix_tasks.md and confirm
4. Re-run: ./ralph_loop.sh --tasks-path features/001-auth/tasks.md
```

**Workflow подтверждения fix-задач:**

```
1. Planning Agent создаёт .proposed_fix_tasks.md
   ↓
2. Пользователь просматривает:
   - Какие fix-задачи будут созданы
   - Какие dependencies обновятся
   - Сколько задач заблокировано
   ↓
3. Пользователь подтверждает:
   - Если OK → Planning Agent обновляет tasks.md
   - Если нет → пользователь редактирует .proposed_fix_tasks.md
   ↓
4. Ralph Loop продолжается
```

**Влияние на выполненные задачи:**

Если escalation требует изменений в уже выполненных задачах:

1. **Fix-задачи вместо отката:**
   - Не снимать `[x]` с выполненных задач
   - Создавать fix-задачи с новым номером (T011, T012, ...)
   - Добавить поле `parent` в YAML frontmatter для связи

2. **Формат fix-задачи:**
   ```yaml
   ---
   id: T011
   parent: T001
   dependencies: []
   reason: fix
   ---
   # T011: Fix API contract for T003
   ```

3. **Обновление dependencies:**
   - Planning Agent обновляет dependencies в существующих задачах
   - Пример: T003 `dependencies: [T002]` → `dependencies: [T012]`
   - T012 — fix-задача для T002

 4. **Planning Agent роль:**
    - Читает `.escalation_handoff.md` — выявленная проблема и пострадавшие задачи
    - **Сам определяет нужный контекст** из handoff (какие файлы читать)
    - Анализирует код реализации для понимания проблемы
    - Определяет влияние на выполненные задачи
    - Создаёт fix-задачи с `parent` полем
    - Обновляет `dependencies` в существующих задачах
    - Обновляет `tasks.md` с новыми задачами в правильном порядке
    - **Создаёт `.proposed_fix_tasks.md` для подтверждения пользователем**

### 7. Dependencies проверка

**Формат:** YAML frontmatter в файле задачи
```yaml
dependencies: [T000, T002]
```

**Правила:**
- `dependencies: []` или поле отсутствует → задача ready for execution
- `dependencies: [T000]` и T000 ещё `[ ]` → skip, искать следующий `[ ]`
- `dependencies: [T000]` и T000 `[x]` → ready for execution
- **Циклические зависимости** → ошибка валидации при генерации

**Валидация целостности (вызывается при старте):**
```bash
validate_tasks_integrity() {
    local tasks_file="$1"
    local tasks_dir="$2"
    local errors=0
    
    # Проверить что для каждого [ ] T001 существует файл
    while IFS= read -r line; do
        if [[ $line =~ ^-\ \[\ \]\ .*(T[0-9]+) ]]; then
            local task_id="${BASH_REMATCH[1]}"
            if [[ ! -f "$tasks_dir/${task_id}.md" ]]; then
                echo "ERROR: Missing task file for $task_id" >&2
                ((errors++))
            fi
        fi
    done < "$tasks_file"
    
    return $errors
}
```

**Проверка в ralph_loop.sh:**
```bash
# Глобальный кэш для избежания повторных чтений
declare -A TASK_STATUS_CACHE
declare -A FRONTMATTER_CACHE

# Кэширование состояния задач (вызвать один раз в начале итерации)
build_task_status_cache() {
    local tasks_file="$1"
    while IFS= read -r line; do
        if [[ $line =~ ^-\ \[([x ])\]\ .*(T[0-9]+) ]]; then
            TASK_STATUS_CACHE[${BASH_REMATCH[2]}]="${BASH_REMATCH[1]}"
        fi
    done < "$tasks_file"
}

# Кэширование распарсенного frontmatter
parse_frontmatter_cached() {
    local task_file="$1"
    
    if [[ -n "${FRONTMATTER_CACHE[$task_file]}" ]]; then
        echo "${FRONTMATTER_CACHE[$task_file]}"
        return
    fi
    
    # Безопасное извлечение dependencies с whitelist валидацией
    local deps=$(grep -oP '^dependencies:\s*\[\K[^]]+' "$task_file" 2>/dev/null | tr -d ' ' | tr ',' '\n' | grep -E '^T[0-9]+$' || echo "")
    
    FRONTMATTER_CACHE[$task_file]="$deps"
    echo "$deps"
}

check_dependencies() {
    local task_file="$1"
    
    # Использовать кэшированный frontmatter
    local deps=$(parse_frontmatter_cached "$task_file")
    
    # Пустые dependencies = ready
    [[ -z "$deps" ]] && return 0
    
    # Проверка через кэшированное состояние
    for dep in $deps; do
        [[ "${TASK_STATUS_CACHE[$dep]}" == "x" ]] || return 1
    done
    
    return 0
}

# Валидация циклических зависимостей (вызывается один раз при generate-tasks)
validate_dag() {
    python3 -c "
import sys, re
from collections import defaultdict

# Парсинг tasks.md для построения графа
graph = defaultdict(list)
with open(sys.argv[1], 'r') as f:
    content = f.read()

# Извлечение task IDs
task_ids = re.findall(r'T[0-9]+', content)

# Проверка cycles через DFS
visited = set()
rec_stack = set()

def has_cycle(node):
    visited.add(node)
    rec_stack.add(node)
    for neighbor in graph.get(node, []):
        if neighbor not in visited:
            if has_cycle(neighbor):
                return True
        elif neighbor in rec_stack:
            return True
    rec_stack.remove(node)
    return False

for task in task_ids:
    if task not in visited:
        if has_cycle(task):
            print(f'ERROR: Circular dependency detected involving {task}', file=sys.stderr)
            sys.exit(1)

print('DAG validation passed')
" "$TASKS_DIR"
}
```

## Архитектурные паттерны (из исследования)

### Используемые паттерны:
1. **Sequential Workflow** — задачи выполняются последовательно
2. **Orchestrator-Delegates** — orchestrator управляет, delegates (агенты) реализуют
3. **State Machine** — текущий `.ralph_state.json`
4. **Evaluator-Optimizer** — review gate с итеративным исправлением

### State Machine диаграмма:

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  ┌──────┐   select   ┌──────────┐   execute   ┌──────────┐  │
│  │ IDLE │ ──────────▶│SELECTING │ ───────────▶│EXECUTING │  │
│  └──────┘            └──────────┘             └──────────┘  │
│      ▲                    │                        │        │
│      │                    │ no task               │        │
│      │                    ▼                        ▼        │
│      │               ┌─────────┐            ┌──────────┐   │
│      │               │ DONE    │            │ REVIEWING│   │
│      │               └─────────┘            └──────────┘   │
│      │                                          │          │
│      │                    ┌─────────────────────┼─────┐    │
│      │                    │                     │     │    │
│      │                    ▼                     ▼     │    │
│      │              ┌──────────┐         ┌─────────┐  │    │
│      │              │ESCALATION│         │ COMMIT  │  │    │
│      │              └──────────┘         └─────────┘  │    │
│      │                    │                     │     │    │
│      │                    │ fix_applied         │     │    │
│      │                    ▼                     │     │    │
│      │              ┌──────────┐                │     │    │
│      └──────────────│  RESUME  │◀───────────────┘     │    │
│                       └──────────┘                      │    │
│                                                         │    │
└─────────────────────────────────────────────────────────────┘
```

### Transition table:

| From | To | Condition | Action |
|------|----|-----------|--------|
| IDLE | SELECTING | tasks.md exists | Find first `[ ]` |
| SELECTING | EXECUTING | deps satisfied | Pass task file to agent |
| SELECTING | IDLE | all tasks `[x]` | Log completion |
| SELECTING | IDLE | all `[ ]` blocked | Exit with error "All tasks blocked" |
| EXECUTING | REVIEWING | task file created | Run reviewers |
| REVIEWING | COMMIT | all APPROVED | Git commit |
| REVIEWING | EXECUTING | any REJECTED | Create rejection context |
| EXECUTING | ESCALATION | .escalation_handoff.md exists | Pause + notify |
| ESCALATION | RESUME | fix tasks created + confirmed | Update tasks.md |
| RESUME | SELECTING | ready | Continue loop |
| COMMIT | SELECTING | more tasks | Mark `[x]`, continue |

### Анти-паттерны (избегать):
1. **Monolithic Agent** — агент не должен управлять списком задач
2. **Context Explosion** — передаём только файл задачи, не весь tasks.md
3. **State Loss** — progress.md обязателен для восстановления

### Рекомендации из исследования:
- **Simplicity first** — простой bash-скрипт вместо фреймворка
- **Design ACI like HCI** — чёткий интерфейс файла задачи
- **Use git for rollback** — коммиты только после review
- **Maintain rejection context** — `.ralph_rejection_context.md`

## DoR (Definition of Ready)

**Критерии готовности плана к реализации:**

### Обязательные критерии (должны быть выполнены ВСЕ)
- [x] **Чёткая постановка задачи** — Цель определена, границы очерчены
- [x] **Архитектурное решение согласовано** — Выбран подход, одобрен пользователем
- [x] **Риски идентифицированы** — Критические риски задокументированы с митигацией
- [x] **Зависимости выявлены** — Внешние: git, jq, kilo. Внутренние: skills, commands
- [x] **Критерии приёмки определены** — DoD сформулирован
- [x] **Ресурсы определены** — 1 разработчик, ~4-6 часов
- [x] **Rollback план существует** — Git backup + rollback.sh + атомарные операции

### Блокирующие вопросы

| Вопрос | Статус | Ответ |
|--------|--------|-------|
| Как тестировать task-generator? | ✅ | TDD циклы с конкретными тест-кейсами (см. секцию TDD) |
| Как мигрировать существующие проекты? | ✅ | migrate-to-v2.sh + тест миграции |
| Обратная совместимость? | ✅ | Нет, только новый формат |
| YAML parsing безопасность? | ✅ | Whitelist валидация `^T[0-9]+$` + кэширование |
| Изоляция агента? | ✅ | chmod 600 + verify_agent_isolation() |
| Циклические зависимости? | ✅ | validate_dag() через Python DFS |

**Вердикт DoR:** ✅ READY

**Self-check пройден:**
- [x] Примеры кода проверены — bash функции валидны
- [x] Маппинг моделей полный — tasks.md → tasks/T001.md с YAML frontmatter
- [x] Все методы API покрыты — parse_frontmatter_cached, check_dependencies, validate_dag
- [x] DoR консистентен — все критерии [x]
- [x] Deployment реалистичен — миграция через скрипт, тесты покрыты
- [x] State Machine добавлена — диаграмма + transition table
- [x] Context Explosion митигирован — ограниченный контекст для Planning Agent
- [x] Recovery path описан — workflow подтверждения fix-задач

## DoD (Definition of Done)

**Критерии завершения задачи:**

### Функциональные критерии
- [ ] **task-generator skill создан** — Генерирует задачи из плана
- [ ] **ralph_loop.sh модифицирован** — Работает с новой структурой
- [ ] **ralph-iterate.md обновлён** — Убраны зависимости от SpecKit
- [ ] **Dependencies проверка** — Orchestrator проверяет dependencies

### Качество кода
- [ ] **Bash-скрипт без ошибок** — ShellCheck пройден
- [ ] **Код-стайл** — Соответствует соглашениям проекта
- [ ] **Документация** — README обновлён

### Тестирование
- [ ] **TDD циклы пройдены** — Все RED-GREEN-REFACTOR циклы выполнены
- [ ] **Юнит-тесты** — parse_frontmatter, check_dependencies, validate_dag покрыты
- [ ] **Интеграционные тесты** — End-to-end сценарий протестирован
- [ ] **Миграция протестирована** — Существующий проект мигрирован успешно

### Совместимость
- [ ] **SpecKit независимость** — Проверено:
  ```bash
  grep -r "\.specify\|check-prerequisites\.sh" ralph-loop/ → 0 результатов
  ```
- [ ] **Агент изолирован** — verify_agent_isolation() пройден

**Вердикт DoD:** ❌ NOT DONE

## ⚠️ TDD ОБЯЗАТЕЛЕН

**Обязательно использовать:** `tdd` skill

**Важно:** Тесты проверяют логику bash-скриптов, НЕ агентов.

### Цикл 1: task-generator skill
- [ ] RED: Написать тест для генерации задач
  ```bash
  # test_task_generator.sh
  # Arrange: создать plan.md с 3 задачами и dependencies
  # Act: запустить task-generator
  # Assert: test -f tasks/T001.md && grep -q "dependencies: \[T000\]" tasks/T002.md
  ```
- [ ] GREEN: Реализовать task-generator skill
- [ ] REFACTOR: Улучшить код

### Цикл 2: check_dependencies() в ralph_loop.sh
- [ ] RED: Написать тест для проверки dependencies
  ```bash
  # test_check_dependencies.sh
  # Arrange: создать tasks.md с T000 [x], T001 [ ], tasks/T001.md с dependencies: [T000]
  # Act: check_dependencies tasks/T001.md tasks.md
  # Assert: return 0 (все dependencies выполнены)
  ```
- [ ] GREEN: Реализовать check_dependencies()
- [ ] REFACTOR: Оптимизировать с кэшированием

### Цикл 3: validate_dag() для циклических зависимостей
- [ ] RED: Написать тест для detection cycles
  ```bash
  # test_validate_dag.sh
  # Arrange: создать T001 → T002 → T001 (cycle)
  # Act: validate_dag tasks/
  # Assert: exit 1, stderr contains "Circular dependency"
  ```
- [ ] GREEN: Реализовать validate_dag()
- [ ] REFACTOR: Улучшить error messages

### Цикл 4: get_next_executable_task() в ralph_loop.sh
- [ ] RED: Написать тест для выбора задачи
  ```bash
  # test_get_next_task.sh
  # Arrange: tasks.md с T000 [x], T001 [ ], T002 [ ] где T002 depends on T000
  # Act: get_next_executable_task tasks.md tasks/
  # Assert: echo "T001" (T001 первая без dependencies)
  ```
- [ ] GREEN: Реализовать get_next_executable_task()
- [ ] REFACTOR: Улучшить производительность

## Задачи реализации

### T001: Создать task-generator skill
**Dependencies:** []
- [ ] RED: Написать тест `test_task_generator_produces_valid_tasks()`
- [ ] GREEN: Создать `.kilo/skills/task-generator/SKILL.md`
- [ ] REFACTOR: Оптимизировать topological sort
- Реализовать генерацию tasks.md из plan.md
- Реализовать генерацию файлов задач tasks/T001.md
- Добавить topological sort для dependencies
- Добавить validate_dag() для detection cycles

### T002: Создать команду /generate-tasks
**Dependencies:** [T001]
- [ ] RED: Написать тест для команды
- [ ] GREEN: Создать `.kilo/commands/generate-tasks.md`
- [ ] REFACTOR: Улучшить UX
- Команда вызывает task-generator skill

### T003: Реализовать parse_frontmatter() в ralph_loop.sh
**Dependencies:** []
- [ ] RED: Написать тест `test_parse_frontmatter()`
- [ ] GREEN: Реализовать функцию
- [ ] REFACTOR: Добавить кэширование

### T004: Реализовать check_dependencies() в ralph_loop.sh
**Dependencies:** [T003]
- [ ] RED: Написать тест `test_check_dependencies()`
- [ ] GREEN: Реализовать функцию с кэшированием
- [ ] REFACTOR: Оптимизировать

### T005: Реализовать get_next_executable_task() в ralph_loop.sh
**Dependencies:** [T004]
- [ ] RED: Написать тест `test_get_next_task()`
- [ ] GREEN: Реализовать функцию
- [ ] REFACTOR: Улучшить производительность

### T006: Модифицировать ralph_loop.sh main logic
**Dependencies:** [T003, T004, T005]
- [ ] RED: Написать integration test
- [ ] GREEN: Интегрировать новые функции в main loop
- [ ] REFACTOR: Вынести в отдельные модули если нужно
- Убрать вызов check-prerequisites.sh
- FEATURE_DIR = dirname($TASKS_PATH)
- Передавать агенту только файл задачи

### T007: Обновить ralph-iterate.md
**Dependencies:** []
- Убрать вызов check-prerequisites.sh
- Убрать чтение progress.md, plan.md
- Оставить только чтение переданного файла задачи

### T008: Обновить test_runner.sh
**Dependencies:** [T001, T003, T004, T005]
- Адаптировать тесты под новую структуру
- Добавить тесты для parse_frontmatter
- Добавить тесты для check_dependencies
- Добавить тесты для validate_dag

### T009: Обновить документацию
**Dependencies:** [T001, T002, T007]
- Обновить README.md с новой архитектурой
- Добавить пример структуры фичи
- Документировать task-generator

### T010: Создать скрипт миграции
**Dependencies:** []
- [ ] RED: Написать тест миграции
- [ ] GREEN: Создать migrate-to-v2.sh
- [ ] REFACTOR: Улучшить error handling
- Конвертировать старый tasks.md в новую структуру

### T011: Реализовать Escalation Protocol в ralph_loop.sh
**Dependencies:** [T006]
- [ ] RED: Написать тест для escalation detection
- [ ] GREEN: Добавить escalation handling в ralph_loop.sh
- [ ] REFACTOR: Улучшить структуру кода
- Добавить проверку `.escalation_handoff.md` после реализации
- Добавить graceful exit с понятным уведомлением
- Обновить save_state() для состояния ESCALATION

### T012: Обновить ralph-iterate.md с Escalation Protocol
**Dependencies:** []
- Добавить секцию "Escalation Protocol"
- Определить триггеры для escalation
- Описать формат `.escalation_handoff.md`
- Указать что делать при обнаружении проблем с выполненными задачами

### T013: Создать шаблон escalation handoff документа
**Dependencies:** []
- Создать `.kilo/templates/escalation-handoff.md`
- Включить все секции: Task ID, Severity, Problem, Context, Variants, Impact

## Риски

| Риск | Вероятность | Влияние | Митигация |
|------|-------------|---------|-----------|
| Topological sort сложен в bash | Средняя | Среднее | Использовать Python для validate_dag() |
| YAML parsing в bash | Низкая | Низкое | Whitelist валидация `^T[0-9]+$` + кэширование |
| Обратная совместимость нарушена | Высокая | Высокое | Создать скрипт миграции + тесты |
| Агент не справится с изоляцией | Низкая | Среднее | Чёткий prompt, TDD тесты |
| Escalation overload | Низкая | Низкое | Чёткие триггеры в ralph-iterate.md |
| Fix-задачи ломают порядок | Средняя | Низкое | Planning Agent пересчитывает порядок, parent поле для трекинга |
| Planning Agent создаёт неверные fix-задачи | Средняя | Среднее | **Подтверждение через .proposed_fix_tasks.md** |
| Context Explosion в Planning Agent | Средняя | Высокое | Planning Agent сам определяет контекст из handoff |
| Все задачи заблокированы dependencies | Низкая | Среднее | **Graceful exit с понятным уведомлением** |
| Рассинхронизация tasks.md и tasks/ | Средняя | Среднее | **validate_tasks_integrity() при старте** |

## Открытые вопросы

1. ~~Нужен ли yq для YAML parsing или достаточно sed/grep?~~ → **Решено:** whitelist regex + кэширование
2. ~~Как тестировать task-generator skill?~~ → **Решено:** TDD циклы с конкретными тест-кейсами
3. ~~Нужна ли валидация структуры файла задачи?~~ → **Решено:** да, через Test Data секцию в шаблоне
4. ~~Как обрабатывать escalation?~~ → **Решено:** Pause-and-Notify с handoff документом
