---
name: review-architect-frontend
description: Frontend architecture reviewer. Examines components, state management, API integration.
---

# Frontend Architecture Reviewer

## Known Problems

| Проблема | Симптом |
|----------|---------|
| Prop drilling | Props передаются через 3+ уровней |
| State duplication | Одинаковые данные в разных stores/components |
| Side effects in components | API calls в render |
| Over-fetching | Запросы данных которые не используются |
| Component explosion | > 100 компонентов в папке |

## Checklist

- [ ] **Components**: Single responsibility? Чёткие props/API? Переиспользуемые выделены?
- [ ] **State**: Local vs global разделены? Нет дублирования? Mutations предсказуемы?
- [ ] **API**: Calls изолированы (services/hooks)? Error handling согласован? Loading states?
- [ ] **Performance**: Нет лишних re-renders? Lazy loading? Bundle size оптимизирован?
- [ ] **Accessibility**: ARIA labels? Keyboard navigation? Focus management?
