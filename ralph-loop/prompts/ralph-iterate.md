ВАЖНО: Отвечай строго на русском языке.

Read the file "$TASKS_PATH". 

Complete AT MOST ONE user story from tasks.md.

Before starting:
1. Run: .specify/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks
2. Parse FEATURE_DIR from output
3. Read FEATURE_DIR/progress.md if exists
4. Read FEATURE_DIR/plan.md for architecture
5. Read FEATURE_DIR/tasks.md for next user story with incomplete tasks `- [ ]`
6. **If .ralph_rejection_context.md exists**: Read it to understand previous review rejection and fix issues

Implement tasks:
- Complete tasks in dependency order
- Follow TDD: write tests first, then implementation
- Run 'dotnet test' after each task
- Mark completed tasks by changing [ ] to [x]

⚠️ КРИТИЧЕСКИ ВАЖНО: НЕ ДЕЛАЙ COMMIT!
- Review произойдёт в следующей фазе
- Просто пометь задачи как [x] когда готово
- Commit будет сделан автоматически после успешного review

Update progress log:
- Append to FEATURE_DIR/progress.md:
  ```markdown
  ## Iteration N - [timestamp]
  **User Story**: [task id or title]
  **Tasks Completed**:
  - [x] Task id: description
  **Files Changed**:
  - path/to/file.ext
  **Status**: IMPLEMENTATION_DONE (awaiting review)
  ```

Stop condition:
- If ALL tasks in current user story are marked [x]:
  Output JSON at the end:
  ```json
  {"signal": "USER_STORY_COMPLETE", "tasks_completed": ["T001", "T002"], "files_changed": ["path/to/file.cs"]}
  ```
- If ALL tasks in tasks.md are complete:
  Output JSON at the end:
  ```json
  {"signal": "COMPLETE"}
  ```

Execute exactly ONE user story and then exit immediately.
