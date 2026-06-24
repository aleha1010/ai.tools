ВАЖНО: Отвечай строго на русском языке.

You will receive a single task file path in the $TASKS_PATH variable.

Before starting:
1. Read the task file at $TASKS_PATH
2. **If .ralph_rejection_context.md exists**: 
   - Read it to understand previous review rejection
   - Fix the SAME task that was rejected
   - DO NOT move to the next task

Implement the task:
- Follow TDD: write tests first, then implementation
- Run tests to verify
- DO NOT mark task as [x] - it will be marked after review

After completing the task, create file "$PENDING_TASKS_FILE":

```json
{
  "task_id": "T005",
  "files_changed": ["path/to/file.cs"],
  "summary": "Краткое описание что сделано"
}
```

This file means: "I finished programming this task, ready for review".

⚠️ КРИТИЧЕСКИ ВАЖНО:
- НЕ делай commit
- НЕ помечай задачу [x]
- НЕ начинай следующую задачу
- НЕ читай tasks.md или другие файлы задач
- Жди review результата

Если review REJECTED, на следующей итерации:
- Прочитай .ralph_rejection_context.md
- Исправь замечания в ТОЙ ЖЕ задаче
- Снова создай $PENDING_TASKS_FILE с тем же task_id

## Escalation Protocol

Если обнаружена проблема, не описанная в задаче:

1. Создай файл `.escalation_handoff.md` в директории фичи с содержимым:

```markdown
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
```

2. НЕ создавай $PENDING_TASKS_FILE
3. Заверши работу — orchestrator обнаружит escalation и остановится

Триггеры для escalation:
- Неописанная зависимость
- Противоречивые требования
- Недостаточно данных в задаче
- Технический блокер
- Scope creep (задача требует изменений в нескольких модулях)

Execute exactly ONE task, create pending file, then exit.
