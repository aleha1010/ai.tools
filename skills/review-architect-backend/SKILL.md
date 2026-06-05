---
name: review-architect-backend
description: Backend architecture reviewer. Examines layered architecture, dependencies, patterns, integrations.
---

# Backend Architecture Reviewer

## Known Problems

| Проблема | Симптом |
|----------|---------|
| Circular dependencies | Domain → Infrastructure → Domain |
| Wrong dependency direction | Infrastructure не должен зависеть от Domain напрямую |
| God classes | Классы > 500 строк или > 10 зависимостей |
| Anemic domain model | Domain entities без поведения |
| Leaky abstractions | Infrastructure details в Domain/Application |

## Checklist

- [ ] **Dependencies**: Направление Api → Infrastructure → Application → Domain? Нет циклов?
- [ ] **Layers**: Domain не зависит от Infrastructure? Application не зависит от Api?
- [ ] **Patterns**: CQRS/Repository используются? Новые паттерны обоснованы?
- [ ] **Integrations**: Внешние сервисы изолированы (interface в Domain, impl в Infrastructure)?
- [ ] **Resilience**: Retry/policies для внешних вызовов? Circuit breaker?
- [ ] **API Design**: REST conventions? Versioning? Consistent error handling?
- [ ] **Domain**: Aggregates правильно определены? Invariants защищены? Domain events?
