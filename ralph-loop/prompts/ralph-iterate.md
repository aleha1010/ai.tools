ВАЖНО: Отвечай строго на русском языке.

Read the file "$TASKS_PATH". 

Complete EXACTLY ONE task from tasks.md per iteration.

Before starting:
1. Run: .specify/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks
2. Parse FEATURE_DIR from output
3. Read FEATURE_DIR/progress.md if exists
4. Read FEATURE_DIR/plan.md for architecture
5. Read FEATURE_DIR/tasks.md for the FIRST incomplete task `- [ ]`
6. **If .ralph_rejection_context.md exists**: 
   - Read it to understand previous review rejection
   - Fix the SAME task that was rejected
   - DO NOT move to the next task

Implement ONE task:
- Follow TDD: write tests first, then implementation
- Run 'dotnet test' to verify
- DO NOT mark task as [x] - it will be marked after review

After completing the task, create file "$PENDING_TASKS_FILE":

```json
{
  "task_id": "T005",
  "files_changed": ["path/to/file.cs"],
  "summary": "Краткое описание что сделано"
}
```

This file means: "I finished programming this task, ready for review".

⚠️ КРИТИЧЕСКИ ВАЖНО:
- НЕ делай commit
- НЕ помечай задачу [x]
- НЕ начинай следующую задачу
- Жди review результата

Если review REJECTED, на следующей итерации:
- Прочитай .ralph_rejection_context.md
- Исправь замечания в ТОЙ ЖЕ задаче
- Снова создай $PENDING_TASKS_FILE с тем же task_id

Execute exactly ONE task, create pending file, then exit.
