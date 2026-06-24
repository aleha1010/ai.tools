# Ralph Loop Architectural Fixes

**Goal**: Fix 3 architectural issues identified during integration testing.

**Created**: 2026-06-24
**Status**: READY FOR IMPLEMENTATION

---

## DoR (Definition of Ready)

**Критерии готовности плана к реализации:**

### Обязательные критерии (должны быть выполнены ВСЕ)
- [x] **Чёткая постановка задачи** — 3 проблемы идентифицированы, решения согласованы
- [x] **Архитектурное решение согласовано** — Подход выбран через интервью
- [x] **Риски идентифицированы** — Нет критических рисков
- [x] **Зависимости выявлены** — Зависит от существующего Ralph Loop
- [x] **Критерии приёмки определены** — DoD сформулирован
- [x] **Ресурсы определены** — Время выполнения ~30-45 минут
- [x] **Rollback план существует** — Git revert

### Блокирующие вопросы

| Вопрос | Статус | Ответ |
|--------|--------|-------|
| Кто генерирует задачи? | ✅ | task-generator skill (интеллектуально) |
| Какой формат task_id? | ✅ | Любой из YAML frontmatter (без валидации) |
| Когда удалять escalation? | ✅ | После завершения task-generator skill |

**Вердикт DoR:** ✅ READY

---

## DoD (Definition of Done)

**Критерии завершения задачи:**

### Функциональные критерии
- [ ] **task-generator работает без bash** — Skill создаёт задачи напрямую
- [ ] **Любые task_id валидны** — Ralph Loop принимает FIX-001, HOTFIX-001, etc.
- [ ] **Escalation очищается** — После обработки task-generator

### Качество
- [ ] **Код-стайл** — Соответствует соглашениям проекта
- [ ] **Документация** — SKILL.md обновлён

### Тестирование
- [ ] **Ручное тестирование** — Все 3 проблемы исправлены
- [ ] **Regression check** — Существующие тесты проходят

**Вердикт DoD:** ❌ NOT DONE (pending execution)

---

## TDD

**Обязательно использовать:** `tdd` skill

### Цикл 1: task-generator skill (интеллектуальный)
- [ ] RED: Тест на генерацию задач из плана (проверка: tasks.md создан, файлы задач созданы, dependencies корректны)
- [ ] GREEN: Реализовать интеллектуальный парсинг plan.md в skill
- [ ] REFACTOR: Удалить generate-tasks.sh

### Цикл 2: Ralph Loop whitelist removal
- [ ] RED: Тест с task_id FIX-001 (должен проходить без ошибок)
- [ ] GREEN: Удалить строки 296-298 в ralph_loop.sh (валидация task_id)
- [ ] REFACTOR: Убедиться, что YAML frontmatter parsing работает

### Цикл 3: Escalation cleanup
- [ ] RED: Тест на удаление escalation после обработки
- [ ] GREEN: Реализовать логику удаления в task-generator skill
- [ ] REFACTOR: Оптимизировать код

---

## Implementation Plan

### Task 1: Удалить generate-tasks.sh

**Objective:** Убрать bash-скрипт, передать функциональность в skill.

**Changes:**
1. Удалить файл: `ralph-loop/scripts/generate-tasks.sh`
2. Обновить `skills/task-generator/SKILL.md`:
   - Убрать вызов bash-скрипта
   - Добавить инструкции по интеллектуальному созданию задач
   - Парсить plan.md, искать секции `### {ID}: {Title}`
   - Извлекать Dependencies из секции задачи
   - Создавать tasks.md с YAML frontmatter
   - Создавать файлы tasks/{ID}.md
   - **Удалить секцию "Валидация"** (или заменить на: "Формат task_id определяется планом")

**New Skill Workflow:**
```
1. Прочитать plan.md
2. Найти все задачи: regex ^###\s+([A-Z0-9-]+):\s+(.+)$
3. Для каждой задачи:
   a. Извлечь Dependencies (если есть)
   b. Создать tasks/{ID}.md с YAML frontmatter
4. Создать tasks.md (индекс)
5. Если существует .escalation_handoff.md:
   a. Проанализировать escalation
   b. Создать fix-задачи (FIX-001, etc.)
   c. Удалить .escalation_handoff.md
```

**Validation:**
- [ ] Skill создаёт задачи из plan.md
- [ ] Dependencies корректны
- [ ] Любые ID поддерживаются (T001, FIX-001, AUTH-001)
- [ ] Escalation обрабатывается

---

### Task 2: Убрать whitelist валидацию в Ralph Loop

**Objective:** Разрешить любые task_id из YAML frontmatter.

**File:** `ralph-loop/scripts/ralph_loop.sh`

**Current code (lines 296-298):**
```bash
if [[ ! "$task_id" =~ ^T[0-9]+$ ]]; then
    print_status "failure" "Некорректный формат task_id: $task_id"
    continue
fi
```

**Action:** Удалить эти 3 строки.

**Rationale:**
- task_id приходит из YAML frontmatter (trusted source)
- Skill `task-generator` создаёт frontmatter
- Валидация формата не нужна (контролируется skill)

**Validation:**
- [ ] FIX-001 задачи выполняются
- [ ] HOTFIX-001 задачи выполняются
- [ ] Существующие T001 задачи работают

---

### Task 3: Escalation cleanup в task-generator

**Dependencies:** Task 1 (требует работающий task-generator skill)

**Objective:** Удалять .escalation_handoff.md после обработки.

**Implementation:** В `task-generator` skill:

1. После создания задач проверить: существует ли `.escalation_handoff.md`?
2. Если да:
   - Прочитать escalation
   - Создать fix-задачи (FIX-001, etc.)
   - Добавить в tasks.md
   - Удалить `.escalation_handoff.md`
   - Log: "Escalation processed and removed"

**Validation:**
- [ ] Escalation файл удалён после обработки
- [ ] Fix-задачи созданы
- [ ] Повторный запуск Ralph Loop не блокируется

---

## Validation Plan

### Manual Testing

1. **Test task-generator (разные ID форматы):**
   ```bash
   # Создать план с разными ID форматами
   echo "### AUTH-001: Setup auth
   Dependencies: none
   
   ### AUTH-002: Add login
   Dependencies: AUTH-001
   
   ### FIX-042: Fix login bug
   Dependencies: AUTH-002
   
   ### HOTFIX-007: Critical patch
   Dependencies: none" > test-plan.md
   
   # Запустить task-generator skill
   # Проверить: 
   # - tasks/AUTH-001.md, tasks/AUTH-002.md созданы
   # - tasks/FIX-042.md создан
   # - tasks/HOTFIX-007.md создан
   # - tasks.md содержит все 4 задачи
   ```

2. **Test Ralph Loop (mixed IDs):**
   ```bash
   # Запустить Ralph Loop с разными ID форматами
   # Ожидается: 
   # - AUTH-001 выполняется без ошибки формата
   # - FIX-042 выполняется без ошибки формата
   # - HOTFIX-007 выполняется без ошибки формата
   ```

3. **Test Escalation:**
   ```bash
   # Создать .escalation_handoff.md
   # Запустить task-generator
   # Ожидается: escalation удалён, FIX-001 создан
   ```

### Regression Check

- [ ] Существующие тесты Ralph Loop проходят (включая test_task_generator.sh)
- [ ] Integration test (T001-T005) работает
- [ ] Обновить test_task_generator.sh: заменить `T[0-9]+` pattern на гибкий regex

---

## Risks & Mitigations

| Риск | Вероятность | Митигация |
|------|-------------|-----------|
| Skill не парсит plan.md корректно | Medium | TDD: тесты на разные форматы |
| Удаление валидации пропускает ошибки | Low | YAML frontmatter — trusted source |
| Escalation удаляется раньше времени | Low | Удаляется только после создания задач |

---

## Rollback Plan

```bash
git revert <commit-hash>
```

---

## Next Steps

1. ⏳ Реализовать Task 1 (task-generator skill)
2. ⏳ Реализовать Task 2 (whitelist removal)
3. ⏳ Реализовать Task 3 (escalation cleanup)
4. ⏳ Валидация
5. ⏳ Commit
