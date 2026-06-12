---
name: kilo-session-search
description: >
  Search and continue Kilo sessions. Use when user mentions 
  "continue session", "find previous conversation", "previous work",
  "вернись к", "продолжи сессию", or references session by name/ID.
  
  MUST run as subagent to preserve current session context.
---

## Trigger Examples (Natural Language)

- "продолжи сессию про review плана"
- "найди сессию где мы делали рефакторинг"
- "continue session ses_145..."
- "вернись к той задаче про базы данных"
- "что мы делали в прошлый раз?"
- "найди предыдущую сессию"

## Workflow

### 1. Parse Intent

Extract from user message:
- **Session ID** (ses_xxx pattern) → go to step 3
- **Session name/description** → search by title (step 2)
- **Vague reference** ("в прошлый раз", "previous") → search recent sessions (empty query)

### 2. Search Sessions

Execute via bash tool:

```bash
sqlite3 ~/.local/share/kilo/kilo.db -json "
SELECT 
  id,
  title,
  agent,
  directory,
  datetime(time_updated/1000, 'unixepoch', 'localtime') as updated,
  (SELECT COUNT(*) FROM session_message WHERE session_id = session.id) as message_count
FROM session
WHERE title LIKE '%' || '<QUERY>' || '%'
ORDER BY time_updated DESC
LIMIT 20
"
```

If query is empty or vague → remove WHERE clause, just ORDER BY time_updated DESC LIMIT 10.

**Results handling:**

- **0 results** → "No sessions found. Try broader search or `/session-search` without query."
- **1 result** → auto-select, show summary (step 3)
- **multiple results** → show numbered list, ask user to reply with number

**Output format for multiple results:**

```markdown
🔍 Found N sessions matching "<query>":

**[1] Session Title Here**
ID: `ses_xxx`
Updated: X hours ago • N messages • agent_type

**[2] Another Session Title**
ID: `ses_yyy`
Updated: ... 

─────────────────────────────
Reply: `1` to view, `continue 1` to resume
```

### 3. Show Session Summary

Execute via bash tool:

```bash
sqlite3 ~/.local/share/kilo/kilo.db -json "
SELECT 
  id,
  title,
  agent,
  directory,
  datetime(time_created/1000, 'unixepoch', 'localtime') as created,
  datetime(time_updated/1000, 'unixepoch', 'localtime') as updated,
  (SELECT COUNT(*) FROM session_message WHERE session_id = session.id) as message_count
FROM session
WHERE id = '<SESSION_ID>'
"
```

Then get first 3 and last 5 messages for summary:

```bash
# First 3 messages
sqlite3 ~/.local/share/kilo/kilo.db -json "
SELECT 
  datetime(time_created/1000, 'unixepoch', 'localtime') as time,
  json_extract(data, '$.role') as role,
  substr(json_extract(data, '$.content'), 1, 300) as preview
FROM session_message
WHERE session_id = '<SESSION_ID>'
ORDER BY time_created
LIMIT 3
"
```

```bash
# Last 5 messages
sqlite3 ~/.local/share/kilo/kilo.db -json "
SELECT 
  datetime(time_created/1000, 'unixepoch', 'localtime') as time,
  json_extract(data, '$.role') as role,
  substr(json_extract(data, '$.content'), 1, 300) as preview
FROM session_message
WHERE session_id = '<SESSION_ID>'
ORDER BY time_created DESC
LIMIT 5
" | jq 'reverse'
```

**Sanitize output**: Filter sensitive patterns BEFORE displaying (see Security section).

**Output format:**

```markdown
📖 Session: <Session Title>
ID: `ses_xxx`

**Metadata:**
• Created: YYYY-MM-DD HH:MM
• Updated: YYYY-MM-DD HH:MM
• Agent: <agent_type>
• Project: <directory>

**Summary:**
• <First message preview or key actions extracted>

**Last messages:**
[HH:MM] ROLE: <message preview>
[HH:MM] ROLE: <message preview>
...

─────────────────────────────
Continue: `/continue ses_xxx` or `continue <number>`
```

### 4. Continue Session

If user wants to continue:

1. **Extract handoff info** from previous session:
   - Read last 10-15 messages to understand context
   - Identify: working directory, files changed, pending tasks, key decisions
   - Generate compact summary (not full history!)

2. **Return to main agent** with:
   - Working directory
   - Last files modified (if mentioned in messages)
   - Pending tasks / open questions
   - Key decisions made
   - Brief summary of what was accomplished

**Do NOT return full message history** — only extracted context.

**Output format:**

```markdown
🔄 Loading session context via handoff...

**Session continued:** <Session Title>

**Context loaded:**
• Working directory: <path>
• Last files: <file1>, <file2>
• Last task: <description>
• Open questions: <questions>

**Progress so far:**
✅ <completed item 1>
✅ <completed item 2>
⏳ <in progress item>

What would you like to do next?
```

### 5. Number Selection

Track search results in memory for number-based selection:

- User replies `1` → select first result from current search
- User replies `continue 1` → continue first result
- Numbers are valid only within current search results (invalidate after new search)

## Security

### Sensitive Data Sanitization

Before displaying any session content, apply these regex replacements:

```regex
# API keys
(?i)(api[_-]?key|apikey)\s*[=:]\s*['"]?[a-zA-Z0-9_-]{20,}

# Passwords
(?i)password\s*[=:]\s*['"]?[^\s'"]{8,}

# Tokens
(?i)(token|bearer)\s*[=:]\s*['"]?[a-zA-Z0-9_-]{20,}

# Secrets
(?i)secret\s*[=:]\s*['"]?[a-zA-Z0-9_-]{20,}

# Connection strings (basic)
(?i)(mongodb|postgres|mysql|redis)://[^\s'"]+

# AWS Access Key IDs
AKIA[A-Z0-9]{16}
```

Replace all matches with `[REDACTED]`.

### First-Run Consent

On first skill use, display warning:

```markdown
⚠️ Security Notice

This skill reads session data from ~/.local/share/kilo/kilo.db
Sessions may contain sensitive information (API keys, credentials).

• Only use on personal machines
• Sensitive values are automatically redacted

Continue? [y/N]
```

Wait for user confirmation before proceeding.

## Error Handling

- **SQLite lock**: Retry with exponential backoff (max 3 attempts, 1s delay)
- **Malformed JSON in messages**: Skip that message, continue with others
- **Session not found**: "Session not found: `<id>`. Use `/session-search` to list available sessions."
- **Empty search result**: "No sessions found. Try broader query or `/session-search` for recent sessions."
- **Invalid session ID format**: "Invalid session ID format. Expected: ses_xxx"

## Output Format

Use Markdown for VS Code rendering. Keep output concise and scannable.

## Implementation Notes

- This skill MUST be invoked as a subagent (task tool) to preserve current session context
- SQL queries use sqlite3 CLI with -json flag for structured output
- Parse JSON output with jq or directly in LLM context
- All timestamps are converted to local time
- Message previews are truncated to 300 characters
