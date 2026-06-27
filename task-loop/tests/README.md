# Тесты Task Loop

## Запуск

```bash
./tests/test_runner.sh
```

## Структура

```
tests/
├── test_runner.sh      # Основной раннер с тестами
└── helpers/
    └── functions.sh    # Моки и хелперы
```

## Покрытие

| Категория | Тесты | Статус |
|-----------|-------|--------|
| validate_path | 3 | ✅ |
| validate_numeric | 4 | ✅ |
| get_first_incomplete_task | 2 | ✅ |
| mark_task_completed | 1 | ✅ |
| save_state | 2 | ✅ |
| print_status | 2 | ✅ |
| run_review_gate | 3 | ✅ |
| circuit breaker | 1 | ✅ |
| **Всего** | **18** | ✅ |

## DI для тестирования

Скрипт поддерживает переопределение команд через переменные окружения:

```bash
KILO_CMD=/path/to/mock_kilo ./scripts/task_loop.sh ...
GIT_CMD=/path/to/mock_git ...
SLEEP_CMD=/path/to/mock_sleep ...
```

## Пример мока для kilo

```bash
#!/bin/bash
# mock_kilo.sh

case "$1" in
    run)
        echo "### Decision: APPROVED"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
```

## Добавление тестов

1. Добавьте функцию `test_*` в `test_runner.sh`
2. Добавьте вызов `run_test "имя" test_*` в `main()`
