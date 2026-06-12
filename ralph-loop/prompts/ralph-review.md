ВАЖНО: Отвечай строго на русском языке.

Run multi-agent review for the last completed user story.

## Context Loading

1. Run: .specify/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks
2. Parse FEATURE_DIR from output
3. Read FEATURE_DIR/tasks.md - find tasks just marked [x] (last completed user story)
4. Read FEATURE_DIR/progress.md - find last iteration entry
5. Read FEATURE_DIR/spec.md - for requirement definitions
6. Read FEATURE_DIR/plan.md - for architecture decisions

## Identify Review Scope

Find the last user story section with tasks marked [x]:
- Extract task IDs (e.g., T001, T002)
- Extract requirements refs (e.g., FR-001, FR-002)
- Extract acceptance criteria from task descriptions
- Identify files changed from progress.md

## Run Reviewers

Use the `task` tool to invoke ALL 5 reviewers IN PARALLEL for efficiency:

```
Call task tool 5 times in a SINGLE message (parallel execution):

Task 1:
  subagent_type: review-analyst
  prompt: |
    Review implementation of tasks {task_ids}:
    Requirements: {FR-refs}
    Acceptance Criteria: {from tasks.md}
    Files Changed: {from progress.md}
    
Task 2:
  subagent_type: review-security
  prompt: |
    Security review for tasks {task_ids}:
    Files Changed: {from progress.md}
    Check: SQL injection, OWASP Top 10
    
Task 3:
  subagent_type: review-architect-backend
  prompt: |
    Architecture review for tasks {task_ids}:
    Files Changed: {from progress.md}
    Verify: DI patterns, layer separation
    
Task 4:
  subagent_type: review-performance
  prompt: |
    Performance review for tasks {task_ids}:
    Files Changed: {from progress.md}
    Check: N+1 queries, AsNoTracking
    
Task 5:
  subagent_type: review-tester
  prompt: |
    Test quality review for tasks {task_ids}:
    Test Files: {from changed files}
    Verify: AAA pattern, edge cases
```

**Wait for ALL 5 tasks to complete before aggregating results.**

## Aggregate Results

Collect verdict from each reviewer and create summary table:

| Reviewer | Verdict | Issues Count |
|----------|---------|--------------|
| analyst | APPROVED / CONDITIONALLY_APPROVED / REJECTED | N |
| security | APPROVED / CONDITIONALLY_APPROVED / REJECTED | N |
| architect | APPROVED / CONDITIONALLY_APPROVED / REJECTED | N |
| performance | APPROVED / CONDITIONALLY_APPROVED / REJECTED | N |
| tester | APPROVED / CONDITIONALLY_APPROVED / REJECTED | N |

## Decision Logic

**If any reviewer REJECTED**:
- Append to progress.md (see format below)
- Output JSON at the end:
  ```json
  {"signal": "REVIEW_REJECTED", "reviewer": "{name}", "issues": ["issue1", "issue2"]}
  ```

**If all APPROVED or CONDITIONALLY_APPROVED**:
- Append to progress.md (see format below)
- Output JSON at the end:
  ```json
  {"signal": "REVIEW_APPROVED", "tasks": ["T001", "T002"], "verdicts": {"analyst": "APPROVED", "security": "APPROVED"}}
  ```

## Update Progress.md

Append structured review entry to FEATURE_DIR/progress.md:

```markdown
---

## Review - [timestamp]

**Tasks**: {task_ids}

### Review Results

| Reviewer | Verdict | CHK | Issues |
|----------|---------|-----|--------|
| analyst | APPROVED / CONDITIONALLY_APPROVED / REJECTED | CHK{N} | {count} HIGH, {count} MEDIUM, {count} LOW |
| security | APPROVED / CONDITIONALLY_APPROVED / REJECTED | CHK{N+1} | {count} HIGH, {count} MEDIUM, {count} LOW |
| architect | APPROVED / CONDITIONALLY_APPROVED / REJECTED | CHK{N+2} | {count} HIGH, {count} MEDIUM, {count} LOW |
| performance | APPROVED / CONDITIONALLY_APPROVED / REJECTED | CHK{N+3} | {count} HIGH, {count} MEDIUM, {count} LOW |
| tester | APPROVED / CONDITIONALLY_APPROVED / REJECTED | CHK{N+4} | {count} HIGH, {count} MEDIUM, {count} LOW |

### Checklist Items

- [{status}] CHK{N}: Tasks {ids} соответствуют требованиям (review-analyst: {verdict})
- [{status}] CHK{N+1}: Tasks {ids} безопасны (review-security: {verdict})
- [{status}] CHK{N+2}: Tasks {ids} архитектура корректна (review-architect: {verdict})
- [{status}] CHK{N+3}: Tasks {ids} производительность в норме (review-performance: {verdict})
- [{status}] CHK{N+4}: Tasks {ids} тесты качественные (review-tester: {verdict})

### Technical Debt

{List issues from CONDITIONALLY_APPROVED reviewers, or "None" if all APPROVED}

### Issues Found

{For each REJECTED or CONDITIONALLY_APPROVED reviewer, list specific issues with severity}

### Decision

{APPROVED: All reviewers passed - commit allowed} | {REJECTED: {reviewer} REJECTED - commit blocked}
```

**CHK Numbering**: Start from CHK001 and increment for each review session (use next available number from existing progress.md entries)

## Exit Signals

- `<promise>REVIEW_APPROVED</promise>` = Commit allowed, all reviewers passed
- `<promise>REVIEW_REJECTED</promise>` = Commit blocked, need fixes

## Important

- Run ALL 5 reviewers even if one rejects (for complete feedback)
- Document technical debt from CONDITIONALLY_APPROVED
- Be thorough - this is a quality gate
- Use CHK numbers sequentially (find last CHK number in progress.md, continue from there)
- Status markers: `[x]` for APPROVED, `[x]` for CONDITIONALLY_APPROVED, `[ ]` for REJECTED
