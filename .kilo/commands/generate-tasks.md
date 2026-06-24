---
description: Generate tasks.md and task files from plan.md
---

# Generate Tasks

Generate Ralph Loop task structure from plan.md.

## Usage

```bash
./ralph-loop/scripts/generate-tasks.sh --plan-path features/001-auth/plan.md
```

## Parameters

- `--plan-path PATH` - Path to plan.md (required)
- `--verbose` - Show detailed output

## What it does

1. Parses plan.md for task definitions (`### T001: Task name`)
2. Extracts dependencies from task descriptions
3. Creates `tasks.md` with task index
4. Creates `tasks/T001.md`, `T002.md`, ... with templates

## Example

Given `features/001-auth/plan.md`:

```markdown
### T001: Setup models
Dependencies: none

### T002: Implement hashing
Dependencies: T001

### T003: Create endpoint
Dependencies: T001, T002
```

Generates:

```
features/001-auth/
  tasks.md           # Task index
  tasks/
    T001.md         # dependencies: []
    T002.md         # dependencies: [T001]
    T003.md         # dependencies: [T001, T002]
```

## Next steps

After generation:
1. Fill in task specifications (test cases, implementation details)
2. Run: `./ralph-loop/scripts/ralph_loop.sh --tasks-path features/001-auth/tasks.md`
