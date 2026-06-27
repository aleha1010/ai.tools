# Skill: review-architect-agent

Эксперт по архитектуре AI-агентных систем для разработки. Анализирует паттерны оркестрации, управления состоянием, dependency resolution и quality gates. Выводит JSON.

## Область применения

Использовать когда:
- Проектируется система с несколькими AI-агентами
- Нужен выбор паттерна оркестрации (sequential, parallel, hierarchical)
- Определяется стратегия управления состоянием
- Проектируются quality gates и review механизмы
- Анализируются риски agent-based архитектур

## Ключевые паттерны оркестрации

### 1. Sequential Workflow

**Описание:** Передача результатов от агента к агенту в определённом порядке.

**Плюсы:**
- Предсказуемый flow выполнения
- Чёткая цепочка зависимостей
- Легко отлаживать

**Минусы:**
- Высокая latency из-за последовательного выполнения
- Ограниченный параллелизм

**Фреймворки:** Semantic Kernel, AutoGen, LangGraph

**Use cases:**
- Document processing pipelines
- Multi-stage code generation
- Step-by-step validation workflows

### 2. Concurrent/Parallel

**Описание:** Параллельный запуск агентов с агрегацией результатов.

**Плюсы:**
- Снижение latency через параллелизацию
- Множество перспектив (voting, ensemble)
- Изоляция сбоев между агентами

**Минусы:**
- Сложность агрегации результатов
- Потенциальные конфликты между выходами

**Фреймворки:** Semantic Kernel, AutoGen, OpenAI Swarm

**Use cases:**
- Parallel code review by multiple agents
- Independent subtask execution
- Ensemble decision making

### 3. Hierarchical/Orchestrator-Workers

**Описание:** Центральный LLM (orchestrator) динамически декомпозирует задачи, делегирует worker-агентам, синтезирует результаты.

**Плюсы:**
- Гибкость в обработке задач
- Адаптивность к непредсказуемым требованиям
- Масштабируемость

**Минусы:**
- Orchestrator — bottleneck
- Сложная обработка ошибок

**Фреймворки:** Anthropic, LangGraph, AutoGen, Semantic Kernel (Magentic)

**Use cases:**
- Complex code changes across multiple files
- Multi-source information gathering
- Dynamic task decomposition

### 4. Handoff/Routing

**Описание:** Динамическая передача управления между агентами на основе контекста или правил.

**Плюсы:**
- Специализация агентов
- Чёткие границы ответственности
- Эффективное использование ресурсов

**Минусы:**
- Требует точных routing decisions
- Overhead на передачу контекста

**Фреймворки:** OpenAI Swarm, Semantic Kernel, AutoGen

**Use cases:**
- Customer service routing (triage → specialist)
- Task escalation and fallback
- Expert handoff scenarios

### 5. Evaluator-Optimizer

**Описание:** Один LLM генерирует, другой оценивает и даёт обратную связь в цикле. Итеративное улучшение до достижения порога качества.

**Плюсы:**
- Более высокое качество output
- Встроенный контроль качества
- Итеративное улучшение

**Минусы:**
- Высокая latency и стоимость
- Риск over-iteration

**Фреймворки:** Anthropic, LangGraph

**Use cases:**
- Literary translation with critique
- Complex search with verification
- Code review and refinement

### 6. Reflection

**Описание:** Агент анализирует свой собственный output, идентифицирует слабости, итеративно улучшает.

**Плюсы:**
- Не требуются дополнительные агенты
- Способность к самоулучшению

**Минусы:**
- Может закреплять ошибки
- Требует хорошей способности к self-critique

**Фреймворки:** AutoGen, LangGraph

**Use cases:**
- Self-correcting code generation
- Quality improvement loops
- Learning from mistakes

## Управление состоянием

### State Graph (LangGraph)

**Описание:** Graph-based state machine с nodes (агенты) и edges (переходы). State persist'ится через сбои, можно resume с checkpoints.

**Плюсы:**
- Durable execution
- Checkpoint/recovery
- Визуализация workflow

**Реализация:**
```python
from langgraph.graph import StateGraph

class AgentState(TypedDict):
    messages: List[Message]
    current_task: str
    results: Dict[str, Any]

graph = StateGraph(AgentState)
graph.add_node("planner", planner_agent)
graph.add_node("executor", executor_agent)
graph.add_node("reviewer", reviewer_agent)
graph.add_edge("planner", "executor")
graph.add_edge("executor", "reviewer")
```

### Actor Model (AutoGen)

**Описание:** Event-driven архитектура с асинхронным messaging. Агенты общаются через messages без shared state.

**Плюсы:**
- Distributed execution
- Масштабируемость across boundaries
- Resilience к failures

**Реализация:**
```python
from autogen import Agent

class WorkerAgent(Agent):
    async def on_message(self, message):
        # Process message
        result = await self.process(message)
        # Send response
        await self.send(result, message.sender)
```

### Context Variables (OpenAI Swarm)

**Описание:** Передача context через function calls и agent handoffs. Простой key-value store доступный агентам.

**Плюсы:**
- Простая реализация
- Легко понять
- Гибкость

**Реализация:**
```python
def transfer_to_agent_b(context_variables):
    return AgentB(context_variables=context_variables)

client.run(
    agent=agent_a,
    messages=[...],
    context_variables={"user_id": "123"}
)
```

## Dependency Resolution

### Topological Ordering

**Описание:** Выполнение задач в порядке зависимостей. Параллельное выполнение независимых задач.

**Use case:** Build systems, deployment pipelines

**Реализация:**
```python
from collections import defaultdict, deque

def topological_sort(tasks):
    graph = defaultdict(list)
    in_degree = {}
    
    for task in tasks:
        in_degree[task.id] = len(task.dependencies)
        for dep in task.dependencies:
            graph[dep].append(task.id)
    
    queue = deque([t for t in tasks if in_degree[t.id] == 0])
    result = []
    
    while queue:
        task = queue.popleft()
        result.append(task)
        for neighbor in graph[task.id]:
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                queue.append(neighbor)
    
    return result if len(result) == len(tasks) else None  # cycle detected
```

### Dynamic Task Queue

**Описание:** Orchestrator поддерживает очередь pending задач, диспатчит по мере разрешения dependencies.

**Use case:** Непредсказуемые графы задач, exploratory work

### Event-Driven Resolution

**Описание:** Задачи эмитят события при завершении, зависимые задачи подписываются и триггерятся.

**Use case:** Distributed systems, microservices

## Quality Gates

### Multi-Reviewer Consensus

**Описание:** Несколько независимых reviewers оценивают output, требуется консенсус для approval.

**Конфигурации:**
- Unanimous approval
- Majority vote
- Weighted scoring

**Фреймворки:** AutoGen, Semantic Kernel

### Human-in-the-Loop

**Описание:** Пауза выполнения для human review на критических checkpoint'ах или при ошибках.

**Триггеры:**
- Before irreversible actions
- On low confidence scores
- At workflow boundaries
- On error detection

**Фреймворки:** LangGraph, AutoGen, Semantic Kernel

**Реализация (LangGraph):**
```python
from langgraph.checkpoint import MemorySaver

checkpointer = MemorySaver()
graph.compile(checkpointer=checkpointer, interrupt_before=["commit"])

# Resume after human approval
graph.invoke(None, config={"thread_id": "session-123"})
```

### Automated Testing Gates

**Описание:** Запуск тестов, линтеров, type checkers перед progression.

**Use cases:**
- Code generation verification
- Build validation
- Integration testing

## Анти-паттерны

### 1. Monolithic Agent

**Проблема:** Один агент отвечает за всё — сложные prompts, деградация performance.

**Решение:** Декомпозиция на специализированные агенты с чёткими responsibilities.

**Impact:** Poor performance, difficult debugging, maintenance nightmare

### 2. Framework Over-abstraction

**Проблема:** Использование сложных фреймворков без понимания underlying code. Abstraction layers скрывают prompts и responses.

**Решение:** Начать с direct LLM API calls, добавлять фреймворки только когда нужно, понимать код под абстракцией.

**Impact:** Difficult debugging, hidden errors, inflexibility

### 3. Premature Autonomy

**Проблема:** Реализация fully autonomous агентов когда достаточно простых workflows.

**Решение:** Начать просто (single LLM call), добавлять сложность только когда demonstrably нужно.

**Impact:** Higher cost, longer latency, unnecessary complexity

### 4. Orchestrator Bottleneck

**Проблема:** Центральный orchestrator становится single point of failure и performance bottleneck.

**Решение:** Иерархическая делегация, разрешить direct agent-to-agent communication где уместно.

**Impact:** Scalability issues, single point of failure

### 5. Infinite Agent Loops

**Проблема:** Агенты попадают в циклы без termination conditions.

**Решение:** Всегда устанавливать max_turns/iteration limits, реализовать termination conditions, добавить cycle detection.

**Impact:** Runaway costs, resource exhaustion

### 6. Context Explosion

**Проблема:** Передача полной истории разговоров через всех агентов, исчерпание context windows.

**Решение:** Summarize intermediate results, selective memory, context pruning.

**Impact:** Token limits exceeded, degraded performance, high costs

### 7. Poor Tool Design

**Проблема:** Tools с неясными интерфейсами, плохой документацией, или форматами сложными для LLMs.

**Решение:** Design agent-computer interfaces (ACI) с той же заботой как human-computer interfaces. Включить examples, edge cases, чёткие boundaries.

**Impact:** Tool misuse, errors, failed tasks

### 8. Error Propagation

**Проблема:** Ошибки от одного агента каскадируют через систему без механизмов восстановления.

**Решение:** Error boundaries, fallback агенты, retry logic с exponential backoff.

**Impact:** Cascading failures, poor user experience

### 9. State Loss

**Проблема:** Отсутствие persist'а state, потеря прогресса при failures.

**Решение:** Durable execution с checkpoints (LangGraph), или явная persistence state.

**Impact:** Lost work, inability to resume, wasted resources

## Best Practices

### Simplicity First

**Принцип:** Начать с простейшего решения. Добавлять сложность только когда это demonstrably улучшает outcomes.

**Пример:** Single LLM call с retrieval и in-context examples → multi-step workflow только когда простое решение недостаточно.

### Transparency in Planning

**Принцип:** Сделать planning шаги агентов явными и видимыми. Включает debugging и trust.

**Пример:** Агент выводит reasoning перед action.

### Design ACI like HCI

**Принцип:** Инвестировать столько же усилий в agent-computer interfaces как в human-computer interfaces.

**Примеры:**
- Чёткая документация tools с examples
- Явные boundaries и edge cases
- Интуитивные parameter names

### Measure and Iterate

**Принцип:** Построить evaluation pipelines. Тестировать с реальными inputs. Итерировать на основе metrics, не предположений.

**Пример:** Benchmark с production data, автоматические тесты для agent outputs.

### Understand Your Tools

**Принцип:** Если используете фреймворки, понимать underlying code. Некорректные предположения — частый источник ошибок.

**Пример:** Прочитать исходники LangGraph перед использованием StateGraph.

### Use Git for Rollback

**Принцип:** Для code-generation агентов использовать git commits на checkpoint'ах для лёгкого rollback.

**Пример:** Атомарные коммиты на каждое логическое изменение.

### Maintain Rejection Context

**Принцип:** Когда reviewers reject work, сохранять rejection reasons и context для следующей итерации.

**Пример:** `.task_loop_rejection_context.md` с причинами отклонения.

### Summarize Intermediate Results

**Принцип:** При передаче state через несколько агентов, суммировать outputs для предотвращения context explosion.

**Пример:** Вместо полной истории разговоров — краткое summary каждого этапа.

### Implement Max Turns Always

**Принцип:** Каждый autonomous agent loop должен иметь iteration limits для предотвращения runaway execution.

**Пример:** `max_turns=50` для agent loops.

## Framework Selection Guide

### LangGraph

**Best for:**
- Long-running, stateful workflows
- Complex state machines с conditional transitions
- Production systems requiring durability и recovery
- Human-in-the-loop критичен

**Trade-offs:** Learning curve, lower-level abstraction

**State Management:** Typed state schema, graph nodes/edges

**Orchestration:** StateGraph с conditional transitions

**Human-in-Loop:** Built-in interrupts для approval/modification

**Deployment:** LangSmith deployment platform

### AutoGen

**Best for:**
- Distributed agent systems
- Multi-language support (Python + .NET)
- Event-driven architectures
- Research и experimentation

**Trade-offs:** Complexity для simple use cases, steeper learning curve

**State Management:** Actor model с message passing, topic subscriptions

**Orchestration:** Agent collaboration patterns, group chat manager

**Human-in-Loop:** Intervention handlers для termination и approval

**Deployment:** Distributed agent runtime via gRPC

### Semantic Kernel

**Best for:**
- Enterprise .NET applications
- Integration с Microsoft ecosystem
- Production-grade agent orchestration

**Trade-offs:** Microsoft-centric, newer agent framework features

**State Management:** Runtime context, kernel state

**Orchestration:** Multiple patterns: Sequential, Concurrent, Handoff, GroupChat, Magentic

**Human-in-Loop:** Agent filters и middleware

**Deployment:** Azure integration

### OpenAI Swarm

**Best for:**
- Lightweight, educational projects
- Simple handoff scenarios
- Learning multi-agent patterns

**Trade-offs:** Educational only, replaced by OpenAI Agents SDK

**State Management:** Context variables dict

**Orchestration:** Agent handoffs via function return

**Human-in-Loop:** Manual implementation needed

**Deployment:** Client-side only, no managed deployment

**Note:** Replaced by OpenAI Agents SDK для production use

### Anthropic Claude (Direct API)

**Best for:**
- Maximum control и transparency
- Simple patterns implemented in few lines of code
- Production systems где framework abstraction obscured behavior

**Trade-offs:** More implementation work, no built-in orchestration primitives

**State Management:** Application-managed

**Orchestration:** Custom implementation (Anthropic provides patterns)

**Human-in-Loop:** Application-managed

**Deployment:** Any infrastructure

## Чеклист для Review

При анализе архитектуры агентной системы проверять:

### Orchestration
- [ ] Выбран подходящий паттерн (sequential/parallel/hierarchical)
- [ ] Нет Monolithic Agent анти-паттерна
- [ ] Orchestrator не является bottleneck

### State Management
- [ ] State persistence реализован
- [ ] Нет State Loss анти-паттерна
- [ ] Context не эксплодирует (summarization)

### Dependencies
- [ ] Dependency resolution определён (topological/dynamic/event-driven)
- [ ] Циклические зависимости обрабатываются
- [ ] Порядок выполнения задач оптимален

### Quality Gates
- [ ] Review механизм определён
- [ ] Human-in-the-loop точки определены (если нужны)
- [ ] Automated testing gates настроены

### Error Handling
- [ ] Error boundaries между агентами
- [ ] Retry logic с exponential backoff
- [ ] Fallback стратегии

### Safety
- [ ] Max iterations/turns установлен
- [ ] Termination conditions определены
- [ ] Rollback механизм существует

### Performance
- [ ] Latency оптимизирована (parallel execution где возможно)
- [ ] Token usage оптимизирован (summarization, pruning)
- [ ] Cost considerations учтены

## Формат вывода

Вернуть JSON:

```json
{
  "verdict": "APPROVED | CONDITIONALLY_APPROVED | REJECTED",
  "findings": [
    {
      "severity": "HIGH | MEDIUM | LOW",
      "category": "Orchestration | State Management | Dependencies | Quality Gates | Error Handling | Safety | Performance",
      "problem": "Описание проблемы",
      "suggestion": "Конкретная рекомендация"
    }
  ],
  "patterns_used": ["Sequential Workflow", "State Machine"],
  "anti_patterns_detected": ["Context Explosion"],
  "recommendations": [
    "Рекомендация 1",
    "Рекомендация 2"
  ]
}
```

## Источники

- Anthropic - Building Effective Agents (December 2024)
- LangGraph Documentation
- OpenAI Swarm GitHub
- AutoGen Documentation
- Semantic Kernel Agent Framework (Microsoft Learn)
