# Ralph Loop - TDD Implementation Orchestrator

Автономный цикл разработки с multi-agent review перед коммитом.

## Структура

```
ralph-loop/
├── README.md
├── prompts/
│   ├── ralph-iterate.md   # Agent prompt для реализации задач
│   └── ralph-review.md    # Agent prompt для мульти-агентного ревью
├── scripts/
│   └── ralph_loop.sh      # Bash orchestrator (state machine)
└── docs/
    └── review-integration-analysis.md
```

## Использование

```bash
# Запуск цикла
./scripts/ralph_loop.sh --tasks-path specs/001-feature/tasks.md

# Без review (для hotfixes)
./scripts/ralph_loop.sh --tasks-path specs/001-feature/tasks.md --no-review

# С verbose output
./scripts/ralph_loop.sh --tasks-path specs/001-feature/tasks.md --verbose
```

## Фазы

```
IDLE → IMPLEMENTING → REVIEWING → COMMITTING → IDLE
              ↓            ↓
           FAILED      REJECTED
```

### PHASE 1: Implementation
- Agent читает `tasks.md`, `progress.md`, `plan.md`
- Реализует одну user story за итерацию
- НЕ делает commit (отложено до review)
- Выводит JSON: `{"signal": "USER_STORY_COMPLETE"}`

### PHASE 2: Review Gate
- Запускает 5 reviewers параллельно:
  - `review-analyst` - бизнес-требования
  - `review-security` - OWASP Top 10, SQL injection
  - `review-architect-backend` - архитектура, DI, слои
  - `review-performance` - N+1 queries, AsNoTracking
  - `review-tester` - AAA pattern, coverage
- При REJECTED: сохраняет `.ralph_rejection_context.md`
- Выводит JSON: `{"signal": "REVIEW_APPROVED"}` или `{"signal": "REVIEW_REJECTED"}`

### PHASE 3: Commit
- Только после REVIEW_APPROVED
- Пытается использовать Spec Kit git extension
- Fallback на прямой `git commit`

## Требования

- `jq` - JSON parsing
- `git` - version control
- `kilo` - AI agent CLI

## Безопасность

- **Command injection**: используется `git commit -F file` вместо `-m`
- **JSON validation**: whitelist сигналов через `select()`
- **File permissions**: LOG/STATE files с `chmod 600`
- **Path traversal**: валидация путей через `realpath`

## State Machine

Состояние сохраняется в `.ralph_state.json`:

```json
{
  "state": "REVIEWING",
  "iteration": 15,
  "current_user_story": "T012",
  "timestamp": "2026-06-12T12:30:00Z",
  "pid": 12345
}
```

## Circuit Breaker

- 3 consecutive failures → остановка
- 2 review failures → остановка
- Exponential backoff: 2^n seconds (max 60s)

## Интеграция с Spec Kit

- Совместим с `specify` commands
- Пытается использовать `.specify/extensions/git/scripts/bash/auto-commit.sh`
- Игнорирует Spec Kit hooks (известное ограничение)

## Known Issues

1. **Нет тестов** для bash-скрипта (рекомендуется bats)
2. **Prompts не тестируются автоматически** (требуется integration tests)
3. **Sleep делает тесты медленными** (требуется DI для SLEEP_CMD)

## История изменений

- **2026-06-12**: Добавлен structured output (JSON), state machine, security fixes
- **2026-06-10**: Создан на базе кастомного скрипта (обход timeout extension)
