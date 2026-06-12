# AI Tools Collection

Коллекция agent tools для разработки с AI.

## Структура

```
ai.tools/
├── agents/              # Agent definitions (wrapper для skills)
├── skills/              # Reusable skills (детальные инструкции + чеклисты)
└── ralph-loop/          # TDD implementation orchestrator
```

## Agents

Agents — это wrapper для вызова skills через Task tool.

| Agent | Skill | Назначение |
|-------|-------|-----------|
| `plan.md` | — | Planning agent для создания архитектурных планов |
| `tdd-implementer.md` | `tdd` | TDD implementation agent (red-green-refactor) |
| `openspec-ralph-iterate.md` | — | Ralph Loop iteration agent |
| `review-analyst.md` | `review-analyst` | Business requirements reviewer |
| `review-architect-backend.md` | `review-architect-backend` | Backend architecture reviewer |
| `review-dba.md` | `review-dba` | Database architecture reviewer |
| `review-performance.md` | `review-performance` | Performance reviewer |
| `review-security.md` | `review-security` | Security reviewer (OWASP) |
| `review-tester.md` | `review-tester` | Test quality reviewer |

**Примечание**: `review-architect-frontend` skill не имеет agent wrapper.

## Skills

### Code Review Suite
| Skill | Назначение |
|-------|-----------|
| `review-analyst` | Бизнес-требования, acceptance criteria |
| `review-architect-backend` | Архитектура backend (.NET, DI, слои) |
| `review-architect-frontend` | Архитектура frontend (React, state, hooks) |
| `review-dba` | Database (EF Core, Dapper, SQL, indexes) |
| `review-performance` | Производительность (N+1, memory, concurrency) |
| `review-security` | Безопасность (OWASP Top 10, SQL injection) |
| `review-tester` | Качество тестов (AAA, coverage, mocks) |

### Kilo Tools
| Skill | Назначение |
|-------|-----------|
| `kilo-session-search` | Поиск и чтение прошлых сессий Kilo |

### Additional Skills (in ~/.config/kilo/skills/)
| Skill | Назначение |
|-------|-----------|
| `tdd` | Test-Driven Development (red-green-refactor) |
| `caveman` | Ultra-compressed communication (~75% token reduction) |
| `grill-me` | Interview user about plan/design decisions |
| `handoff` | Create handoff document for another agent |

## Ralph Loop

Автономный TDD цикл с multi-agent review перед коммитом.

```bash
./ralph-loop/scripts/ralph_loop.sh --tasks-path specs/001-feature/tasks.md
```

**Фазы**:
1. **Implementation** - agent реализует задачи из tasks.md
2. **Review Gate** - 5 reviewers проверяют код параллельно
3. **Commit** - только после APPROVED

**JSON Protocol**:
```json
{"signal": "USER_STORY_COMPLETE", "tasks_completed": ["T001"]}
{"signal": "REVIEW_APPROVED", "verdicts": {"security": "APPROVED"}}
{"signal": "REVIEW_REJECTED", "reviewer": "security", "issues": ["SQL injection"]}
```

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
Скопируйте `ralph-loop/` в корень проекта или настройте путь:
```bash
./ralph-loop/scripts/ralph_loop.sh --tasks-path PATH
```

## Использование Skills

```markdown
<!-- В агент prompt -->
Use skill tool:
skill: review-security
input: Security review for changed files
```

## Требования

- `kilo` CLI (или совместимый AI agent)
- `jq` для Ralph Loop
- `git` для version control

## Лицензия

MIT
