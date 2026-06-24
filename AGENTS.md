# AI Tools Repository

Collection of agent tools for AI-assisted development: agents, skills, and Ralph Loop orchestrator.

## Structure

```
agents/              # Agent definitions (wrappers for Task tool → skills)
skills/              # Reusable instruction files (SKILL.md per skill)
ralph-loop/          # Autonomous TDD orchestrator with multi-agent review
```

## Skills

Skills are loaded via `kilo.json`:

```json
{
  "skills": {
    "paths": ["~/Workspace/ai.tools/skills"]
  }
}
```

Each skill is a directory with `SKILL.md`. Use via `skill` tool:

```
skill: review-security
```

### Available Skills

| Skill | Purpose |
|-------|---------|
| `review-analyst` | Business requirements, acceptance criteria, edge cases |
| `review-architect-backend` | Backend architecture (.NET, DI, layers, dependencies) |
| `review-architect-frontend` | Frontend architecture (React, state, hooks, performance) |
| `review-dba` | Database (EF Core, Dapper, SQL, indexes, migrations) |
| `review-performance` | Performance (N+1, memory, concurrency, caching) |
| `review-security` | Security (OWASP Top 10, SQL injection, XSS, auth) |
| `review-tester` | Test quality (AAA, coverage, mocks, assertions) |
| `kilo-session-search` | Search and continue previous Kilo sessions |

## Agents

Agents are wrappers that call skills via Task tool. Located in `agents/*.md`.

| Agent | Skill | When to use |
|-------|-------|-------------|
| `tdd-implementer` | `tdd` | TDD implementation with red-green-refactor |
| `review-*` | `review-*` | Structured code review for specific domain |

## Ralph Loop

Autonomous TDD orchestrator: **Implementation → Review → Commit**.

### Requirements

- `kilo` CLI
- `jq` >= 1.6
- `git` >= 2.0

### Usage

```bash
./ralph-loop/scripts/ralph_loop.sh --tasks-path specs/001-feature/tasks.md
```

### Key Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--tasks-path PATH` | required | Path to tasks.md |
| `--max-iterations N` | 50 | Max iterations (1-1000) |
| `--no-review` | false | Skip review gate (hotfix only) |
| `--verbose` | false | Detailed output |

### Workflow

1. **Phase 1**: Implement ONE task from tasks.md
2. **Phase 2**: Run 5 parallel reviewers (analyst, security, architect, performance, tester)
3. **Phase 3**: Commit only if APPROVED

### Generated Files

| File | Purpose |
|------|---------|
| `.ralph_state.json` | State machine tracking |
| `.ralph_loop.log` | Execution log |
| `.ralph_rejection_context.md` | Context for fixing REJECTED tasks |

### Testing

```bash
./ralph-loop/tests/test_runner.sh
```

Uses DI via env vars: `KILO_CMD`, `GIT_CMD`, `SLEEP_CMD`.

## Conventions

- Skills output JSON for programmatic parsing
- Agents defined with YAML frontmatter (description, mode, permissions)
- Review skills use severity: HIGH (blocking), MEDIUM, LOW
- All review verdicts: `APPROVED`, `CONDITIONALLY_APPROVED`, `REJECTED`
