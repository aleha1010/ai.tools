# Ralph Loop

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Автономный TDD-оркестратор с мульти-агентным ревью перед коммитом.

## Обзор

Ralph Loop автоматизирует цикл реализации: **Реализация → Ревью → Коммит**. Качество кода обеспечивается запуском 5 специализированных review-агентов перед каждым коммитом.

```
┌─────────────────────────────────────────────────────┐
│                    Ralph Loop                        │
│                                                      │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐       │
│  │Реализация│───▶│  Ревью   │───▶│  Коммит  │       │
│  │  Агент   │    │  (5 шт)  │    │          │       │
│  └──────────┘    └──────────┘    └──────────┘       │
│       │               │                              │
│       │          ┌────┴────┐                        │
│       │          │         │                        │
│       │     APPROVED  REJECTED                       │
│       │          │         │                         │
│       │          ▼         ▼                         │
│       │       Коммит   Исправление                   │
└──────┴──────────────────────────────────────────────┘
```

## Возможности

- **Двухфазный подход**: Реализация отделена от коммита
- **Мульти-агентное ревью**: 5 специализированных ревьюеров параллельно
- **State Machine**: Явное отслеживание состояния с поддержкой восстановления
- **Circuit Breaker**: Остановка после 3 последовательных неудач
- **Структурированный вывод**: JSON-протокол коммуникации
- **Интеграция с Spec Kit**: Совместим с командами specify

## Быстрый старт

```bash
# Базовый запуск
./scripts/ralph_loop.sh --tasks-path specs/001-feature/tasks.md

# Без ревью (только для hotfix)
./scripts/ralph_loop.sh --tasks-path specs/001-feature/tasks.md --no-review

# Подробный вывод
./scripts/ralph_loop.sh --tasks-path specs/001-feature/tasks.md --verbose
```

## Требования

| Зависимость | Версия | Назначение |
|-------------|--------|------------|
| `kilo` | любая | AI agent CLI |
| `jq` | >=1.6 | Парсинг JSON |
| `git` | >=2.0 | Контроль версий |

## Архитектура

### Структура директорий

```
ralph-loop/
├── README.md
├── scripts/
│   └── ralph_loop.sh      # Bash-оркестратор
└── prompts/
    ├── ralph-iterate.md   # Prompt агента реализации
    └── ralph-review.md    # Prompt агента ревью
```

### State Machine

```
         ┌──────────────────────────────────────┐
         │                                      │
         ▼                                      │
       IDLE ──────▶ IMPLEMENTING ──────▶ REVIEWING
         │                │                   │
         │                │                   │
         │                ▼                   ▼
         │            FAILED             ┌────┴────┐
         │                │              │         │
         │                │         APPROVED  REJECTED
         │                │              │         │
         │                │              ▼         │
         │                │         COMMITTING     │
         │                │              │         │
         │                │              ▼         │
         │                │           IDLE ◀──────┘
         │                │                          
         ▼                ▼                          
      COMPLETE         (circuit breaker)            
```

### Фазы

#### Фаза 1: Реализация

Агент (`ralph-iterate.md`):
1. Читает `tasks.md`, `progress.md`, `plan.md`
2. Реализует одну user story
3. Помечает задачи как `[x]`
4. Выводит: `{"signal": "USER_STORY_COMPLETE"}`

#### Фаза 2: Review Gate

Агент (`ralph-review.md`):
1. Определяет выполненные задачи
2. Запускает 5 ревьюеров параллельно:

| Ревьюер | Фокус |
|---------|-------|
| `review-analyst` | Бизнес-требования, acceptance criteria |
| `review-security` | OWASP Top 10, SQL injection, XSS |
| `review-architect-backend` | DI-паттерны, разделение слоёв |
| `review-performance` | N+1 queries, memory leaks, async |
| `review-tester` | AAA pattern, coverage, mocks |

3. Агрегирует результаты
4. Выводит: `{"signal": "REVIEW_APPROVED"}` или `{"signal": "REVIEW_REJECTED"}`

#### Фаза 3: Коммит

Оркестратор (`ralph_loop.sh`):
1. Создаёт git commit (только после APPROVED)
2. Включает статус ревью в сообщение коммита
3. Обновляет progress log

## Конфигурация

### Параметры командной строки

| Параметр | Обязательный | По умолчанию | Описание |
|----------|--------------|--------------|----------|
| `--tasks-path PATH` | Да | — | Путь к tasks.md |
| `--max-iterations N` | Нет | 50 | Максимум итераций (1-1000) |
| `--no-review` | Нет | false | Отключить Review Gate |
| `--verbose` | Нет | false | Подробный вывод |
| `--working-directory DIR` | Нет | . | Рабочая директория |

### Переменные окружения

| Переменная | Описание |
|------------|----------|
| `KILO_CMD` | Переопределить команду kilo (для тестов) |
| `RALPH_TEST_MODE` | `true` для отключения sleep в тестах |

## JSON-протокол

### Реализация завершена

```json
{
  "signal": "USER_STORY_COMPLETE",
  "tasks_completed": ["T001", "T002"],
  "files_changed": ["src/Service.cs", "tests/ServiceTests.cs"]
}
```

### Ревью пройдено

```json
{
  "signal": "REVIEW_APPROVED",
  "tasks": ["T001", "T002"],
  "verdicts": {
    "analyst": "APPROVED",
    "security": "APPROVED",
    "architect": "CONDITIONALLY_APPROVED",
    "performance": "APPROVED",
    "tester": "APPROVED"
  }
}
```

### Ревью отклонено

```json
{
  "signal": "REVIEW_REJECTED",
  "reviewer": "security",
  "issues": [
    "SQL injection в методе GetParticipants",
    "Отсутствует валидация входных данных"
  ]
}
```

### Все задачи выполнены

```json
{
  "signal": "COMPLETE"
}
```

## Генерируемые файлы

| Файл | Назначение | Права |
|------|------------|-------|
| `.ralph_state.json` | State machine tracking | 600 |
| `.ralph_loop.log` | Лог выполнения | 600 |
| `.ralph_rejection_context.md` | Контекст для исправления REJECTED | 600 |

### Формат Progress Log

Дописывается в `specs/*/progress.md`:

```markdown
## Review - 2026-06-12T12:30:00Z

**Задачи**: T001, T002

### Результаты ревью

| Ревьюер | Вердикт | CHK | Проблемы |
|---------|---------|-----|----------|
| analyst | APPROVED | CHK001 | 0 HIGH, 0 MEDIUM, 0 LOW |
| security | APPROVED | CHK002 | 0 HIGH, 0 MEDIUM, 0 LOW |
| architect | CONDITIONALLY_APPROVED | CHK003 | 0 HIGH, 1 MEDIUM, 0 LOW |
| performance | APPROVED | CHK004 | 0 HIGH, 0 MEDIUM, 0 LOW |
| tester | APPROVED | CHK005 | 0 HIGH, 0 MEDIUM, 0 LOW |

### Checklist Items

- [x] CHK001: Задачи T001,T002 соответствуют требованиям
- [x] CHK002: Задачи T001,T002 безопасны
- [x] CHK003: Задачи T001,T002 архитектура корректна
- [x] CHK004: Задачи T001,T002 производительность в норме
- [x] CHK005: Задачи T001,T002 тесты качественные

### Technical Debt

Нет

### Решение

APPROVED: Все ревьюеры прошли — коммит разрешён
```

## Обработка ошибок

### Circuit Breaker

- **3 последовательных неудачи реализации** → Остановка
- **2 последовательных неудачи ревью** → Остановка
- **Exponential backoff**: 2^n секунд (макс 60с)

### Восстановление

При REJECTED:
1. Контекст сохраняется в `.ralph_rejection_context.md`
2. Задачи остаются помеченными `[x]`
3. Следующая итерация читает контекст и исправляет проблемы

## Безопасность

### Меры защиты

| Угроза | Защита |
|--------|--------|
| Command injection | Используется `git commit -F file` вместо `-m` |
| JSON injection | Whitelist-валидация через `jq select()` |
| Path traversal | Валидация `realpath` относительно корня проекта |
| Права файлов | `chmod 600` для log/state файлов |

### Исправленные HIGH-находки

Все HIGH-находки из security review исправлены:
- ✅ Command injection в git commit
- ✅ Непроверенный JSON parsing
- ✅ Проблемы с правами файлов

## Известные ограничения

| Ограничение | Влияние | Митигация |
|-------------|---------|-----------|
| Нет тестов для bash-скрипта | Среднее | Использовать bats для критических путей |
| Prompts не тестируются автоматически | Среднее | Integration tests с mock kilo |
| Sleep замедляет тесты | Низкое | Переопределить `SLEEP_CMD` в тестах |

## Changelog

### [1.1.0] - 2026-06-12

#### Добавлено
- Структурированный JSON output protocol
- State machine с `.ralph_state.json`
- Файл контекста отклонения для восстановления
- Поддержка параллельного выполнения ревью
- Проверка зависимостей `jq` и `git`

#### Изменено
- Review Gate: signal-based → JSON-based протокол
- Подсчёт задач: исправлен баг подсчёта всех задач вместо новых
- Git commit: теперь использует file-based message (security fix)

#### Исправлено
- Command injection уязвимость в git commit
- JSON parsing без валидации
- Некорректный подсчёт выполненных задач

#### Безопасность
- Добавлен `chmod 600` для log и state файлов
- Whitelist-валидация для JSON signals
- File-based commit messages

### [1.0.0] - 2026-06-10

#### Добавлено
- Начальная реализация
- Двухфазный подход (реализация → ревью → коммит)
- Мульти-агентное Review Gate
- Circuit Breaker
- Exponential backoff

## Установка в проект

```bash
# Копирование в проект
cp -r /Users/alexey/Workspace/ai.tools/ralph-loop ./

# Запуск
./ralph-loop/scripts/ralph_loop.sh --tasks-path specs/001-feature/tasks.md
```

## Лицензия

MIT License — см. файл LICENSE.
