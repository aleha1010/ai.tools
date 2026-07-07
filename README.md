# AI Tools Collection

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Коллекция agent tools для разработки с AI.

## Обзор

Репозиторий содержит переиспользуемые компоненты для AI-разработки:
- **Agents** — определения агентов (wrapper для skills)
- **Skills** — детальные инструкции и чеклисты для анализа
- **Task Loop** — автономный TDD-оркестратор

## Структура

```
ai.tools/
├── agents/              # Определения агентов
├── skills/              # Переиспользуемые навыки
└── task-loop/           # TDD-оркестратор
```

## Agents

Agents — это wrapper для вызова skills через Task tool.

| Agent | Skill | Назначение |
|-------|-------|-----------|
| `plan.md` | — | Planning agent для архитектурных планов |
| `tdd-implementer.md` | `tdd` | TDD реализация (red-green-refactor) |
| `review-analyst.md` | `review-analyst` | Ревью бизнес-требований |
| `review-architect-backend.md` | `review-architect-backend` | Ревью backend-архитектуры |
| `review-architect-frontend.md` | `review-architect-frontend` | Ревью frontend-архитектуры |
| `review-dba.md` | `review-dba` | Ревью database-архитектуры |
| `review-performance.md` | `review-performance` | Ревью производительности |
| `review-security.md` | `review-security` | Ревью безопасности (OWASP) |
| `review-tester.md` | `review-tester` | Ревью качества тестов |

## Skills

### Code Review Suite

| Skill | Назначение |
|-------|-----------|
| `review-analyst` | Бизнес-требования, acceptance criteria, edge cases |
| `review-architect-backend` | Архитектура backend (.NET, DI, слои, зависимости) |
| `review-architect-frontend` | Архитектура frontend (React, state, hooks, performance) |
| `review-dba` | Database (EF Core, Dapper, SQL, indexes, migrations) |
| `review-performance` | Производительность (N+1, memory, concurrency, caching) |
| `review-security` | Безопасность (OWASP Top 10, SQL injection, XSS, auth) |
| `review-tester` | Качество тестов (AAA, coverage, mocks, assertions) |

### Kilo Tools

| Skill | Назначение |
|-------|-----------|
| `kilo-session-search` | Поиск и чтение прошлых сессий Kilo |

### Дополнительные skills (в ~/.config/kilo/skills/)

| Skill | Назначение |
|-------|-----------|
| `tdd` | Test-Driven Development (red-green-refactor) |
| `grill-me` | Интервью пользователя о плане/дизайне |
| `grilling` | Движок интервью (вызывается из grill-me) |
| `handoff` | Создание handoff-документа для другого агента |

## Task Loop

Автономный TDD цикл с multi-agent review перед коммитом.

### Быстрый старт

```bash
./task-loop/scripts/task_loop.sh --tasks-path specs/001-feature/tasks.md
```

### Фазы

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Реализация  │────▶│    Ревью     │────▶│    Коммит    │
│   (Agent)    │     │ (5 агентов)  │     │    (Git)     │
└──────────────┘     └──────────────┘     └──────────────┘
       │                    │
       │              ┌─────┴─────┐
       │              │           │
       │          APPROVED   REJECTED
       │              │           │
       │              ▼           ▼
       │           Коммит    Исправление
```

### JSON Protocol

```json
{"signal": "USER_STORY_COMPLETE", "tasks_completed": ["T001"]}
{"signal": "REVIEW_APPROVED", "verdicts": {"security": "APPROVED"}}
{"signal": "REVIEW_REJECTED", "reviewer": "security", "issues": ["SQL injection"]}
```

Подробнее: [task-loop/README.md](task-loop/README.md)

## Установка skills

### Откуда брать skills

Часть skills поставляется из репозитория [mattpocock/skills](https://github.com/mattpocock/skills).

**Установка:**

```bash
# Клонировать репозиторий
git clone --depth 1 https://github.com/mattpocock/skills.git /tmp/mattpocock-skills

# Скопировать нужные skills (engineering)
for skill in to-issues implement code-review tdd domain-modeling grill-with-docs to-prd; do
  cp -r "/tmp/mattpocock-skills/skills/engineering/$skill" ~/.config/kilo/skills/"$skill"
done

# Скопировать нужные skills (productivity)
for skill in grill-me handoff grilling; do
  cp -r "/tmp/mattpocock-skills/skills/productivity/$skill" ~/.config/kilo/skills/"$skill"
done
```

### Список skills и их происхождение

| Skill | Источник | Модификация |
|-------|----------|-------------|
| `to-issues` | mattpocock | ✅ **Модифицирован** — см. инструкцию ниже |
| `implement` | mattpocock | Оригинал |
| `code-review` | mattpocock | Оригинал |
| `tdd` | mattpocock | Оригинал |
| `domain-modeling` | mattpocock | Оригинал |
| `grill-with-docs` | mattpocock | Оригинал |
| `to-prd` | mattpocock | Оригинал |
| `grill-me` | mattpocock | ✅ **Модифицирован** — см. инструкцию ниже |
| `grilling` | mattpocock | Оригинал |
| `handoff` | mattpocock | ✅ **Модифицирован** — см. инструкцию ниже |
| `review-*` (7 skills) | ai.tools (собственные) | — |
| `escalation` | ai.tools (собственный) | — |
| `kilo-session-search` | ai.tools (собственный) | — |

### Инструкции по модификации

#### `to-issues`

Заменить шаг 5 (Publish to issue tracker) на сохранение в локальные файлы. Конкретно:

1. Удалить шаг 5 полностью.
2. Добавить новый шаг 5 — "Save issues as local task files" со следующей структурой:

```
{output_path}/
├── tasks.md          # индекс задач
├── progress.md       # прогресс (пустой)
└── tasks/
    ├── T001.md       # задача 1
    ├── T002.md       # задача 2
    └── ...
```

Где `{output_path}` = `.kilo/plans/{feature-name}/`. Формат `tasks.md` — checklist (совместимость с task-loop), ID задач строго `T001`, `T002`, ...

3. Удалить все упоминания issue tracker, references, triage labels, `setup-matt-pocock-skills`.
4. Удалить шаблон issue-template, заменить на task-template с YAML frontmatter:

```markdown
---
id: T001
dependencies: []
---

# T001: {Title}

## What to build

...

## Acceptance Criteria

- [ ] ...

## Blocked by

- None — can start immediately
```

5. Добавить в конец файла: `Do NOT attempt to publish issues to external issue trackers (JIRA, GitHub Issues, GitLab, etc.) unless the user explicitly asks for it.`

#### `grill-me`

После заглушки `Run a /grilling session.` добавить строку: `Веди интервью на русском языке.`

Также скопировать `grilling` skill из `mattpocock/skills/productivity/grilling/` — он обязателен, так как `grill-me` на него ссылается.

#### `handoff`

Взять оригинал из mattpocock (с `disable-model-invocation: true`). После секции инструкций (строка 16) добавить блок:

```markdown
## Обязательные секции (если применимо)

### ⚠️ TDD Contract

Для задач с кодом ОБЯЗАТЕЛЬНО включить:

\```
## ⚠️ TDD Contract

**Пользователь ВИДИТ каждое действие в реальном времени.**

- [ ] Тест написан ДО кода?
- [ ] Тест падал на RED фазе?
- [ ] Код минимальный?

**Нарушение TDD = изменения не приняты.**
\```
```

### В kilo.json

```json
{
  "skills": {
    "paths": ["~/Workspace/ai.tools/skills"]
  }
}
```

### В проекте

Скопируйте `task-loop/` в корень проекта:

```bash
cp -r /Users/alexey/Workspace/ai.tools/task-loop ./
./task-loop/scripts/task_loop.sh --tasks-path specs/001-feature/tasks.md
```

## Использование

### Вызов skill из agent prompt

```markdown
Use skill tool:

skill: review-security
input: |
  Security review for changed files:
  - src/Repository.cs
  - src/Service.cs
  
  Check for: SQL injection, OWASP Top 10
```

### Вызов агента через Task tool

```markdown
Task tool → subagent_type: review-security

Prompt: Review implementation of GetParticipants method for SQL injection vulnerabilities.
```

## Требования

| Зависимость | Версия | Назначение |
|-------------|--------|------------|
| `kilo` | any | AI agent CLI |
| `jq` | >=1.6 | JSON parsing (Task Loop) |
| `git` | >=2.0 | Version control |

## Лицензия

MIT License — см. [LICENSE](LICENSE).
