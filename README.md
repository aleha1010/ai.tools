# AI Tools Collection

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Коллекция agent tools для разработки с AI.

## Обзор

Репозиторий содержит переиспользуемые компоненты для AI-разработки:
- **Agents** — определения агентов (wrapper для skills)
- **Skills** — детальные инструкции и чеклисты для анализа
- **Ralph Loop** — автономный TDD-оркестратор

## Структура

```
ai.tools/
├── agents/              # Определения агентов
├── skills/              # Переиспользуемые навыки
└── ralph-loop/          # TDD-оркестратор
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
| `caveman` | Ультра-сжатая коммуникация (~75% экономия токенов) |
| `grill-me` | Интервью пользователя о плане/дизайне |
| `handoff` | Создание handoff-документа для другого агента |

## Ralph Loop

Автономный TDD цикл с multi-agent review перед коммитом.

### Быстрый старт

```bash
./ralph-loop/scripts/ralph_loop.sh --tasks-path specs/001-feature/tasks.md
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

Подробнее: [ralph-loop/README.md](ralph-loop/README.md)

## Установка

### В kilo.json

```json
{
  "skills": {
    "paths": ["~/Workspace/ai.tools/skills"]
  }
}
```

### В проекте

Скопируйте `ralph-loop/` в корень проекта:

```bash
cp -r /Users/alexey/Workspace/ai.tools/ralph-loop ./
./ralph-loop/scripts/ralph_loop.sh --tasks-path specs/001-feature/tasks.md
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
| `jq` | >=1.6 | JSON parsing (Ralph Loop) |
| `git` | >=2.0 | Version control |

## Лицензия

MIT License — см. [LICENSE](LICENSE).
