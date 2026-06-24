# Автовыбор ролей для ревью

## Таблица автовыбора

| Тип задачи   | Скиллы для запуска                                             |
|--------------|----------------------------------------------------------------|
| Backend API  | `review-architect-backend`, `review-security`                  |
| Frontend     | `review-architect-backend`, `review-performance`               |
| Database     | `review-dba`, `review-security`                                |
| Integration  | `review-architect-backend`, `review-security`, `review-analyst`|
| Full-stack   | `review-architect-backend`, `review-security`, `review-performance`, `review-dba` |

## Приоритет при конфликте

security → analyst → review-architect-backend → performance → dba

## Определение типа задачи

- **Backend API** — контроллеры, сервисы, репозитории, бизнес-логика
- **Frontend** — UI компоненты, стили, клиентский код
- **Database** — миграции, SQL, индексы, ORM маппинги
- **Integration** — внешние API, HTTP клиенты, message queues
- **Full-stack** — изменения затрагивают несколько слоёв
