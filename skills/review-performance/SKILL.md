---
name: review-performance
description: Performance reviewer. Examines bottlenecks, caching, scaling strategies.
---

# Performance Reviewer

## Known Problems

| Проблема | Симптом |
|----------|---------|
| Sync over async | `.Result`, `.Wait()` в async методе |
| Blocking IO | File/HTTP calls без async |
| Memory leaks | Неосвобождённые resources, event handlers |
| Cache stampede | Multiple requests warming cache одновременно |
| Unbounded collections | Lists без capacity, строки без StringBuilder |

## Checklist

- [ ] **Bottlenecks**: IO-bound vs CPU-bound определено? Async где необходимо?
- [ ] **Caching**: Strategy определена? Invalidation корректна? Distributed cache если нужно?
- [ ] **Resources**: Memory leaks prevention? Connection pooling? IDisposable implemented?
- [ ] **Scaling**: Horizontal scaling возможен? Stateless design? Load balancing учтён?
- [ ] **Monitoring**: Performance baseline? Metrics integration? Alerting thresholds?
