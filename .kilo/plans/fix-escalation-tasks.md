# Fix Escalation Tasks

This plan contains fixes for T005 escalation impact on completed tasks.

## Escalation Impact

T005 escalation revealed that completed tasks T001-T003 need updates to support database configuration validation.

---

### FIX-001: Update T001 Output File

Dependencies: none

Add database configuration placeholder to test file created in T001.

Objective: Update test_output.txt to include DB_URL placeholder for T005 validation.

Implementation:
```bash
echo "DB_URL=placeholder://localhost:5432/testdb" >> test_output.txt
```

---

### FIX-002: Update T002 Config Format

Dependencies: FIX-001

Replace hardcoded password with environment variable reference in config.json.

Objective: Update config.json to use environment variable instead of hardcoded password.

Implementation:
```bash
cat > config.json << 'EOF'
{
  "password": "${DB_PASSWORD}",
  "db_url_ref": "test_output.txt"
}
EOF
```

---

### FIX-003: Add Database Config to T003

Dependencies: FIX-002

Add database configuration section to app_config.yaml.

Objective: Extend app_config.yaml with database connection settings for T005 validation.

Implementation:
```bash
cat >> app_config.yaml << 'YAML'

database:
  connection:
    url: "${DB_URL}"
    pool_size: 10
    timeout: 30s
YAML
```

---

### FIX-004: Redesign T005 as Validation Task

Dependencies: FIX-001, FIX-002, FIX-003

Redesign T005 to validate database configuration instead of requiring production access.

Objective: Create a test scenario where T005 validates configuration files and triggers escalation when it detects placeholders.

Implementation Instructions for Kilo:
1. Read test_output.txt and extract DB_URL
2. Read config.json and check password format
3. Read app_config.yaml database section
4. Validate that DB_URL is a real connection string (not "placeholder")
5. If placeholder detected → create ${FEATURE_DIR}/.escalation_handoff.md
6. Document that configuration contains placeholders
7. Do NOT create .ralph_pending_tasks.json
8. Exit with code 0

Expected Result: Escalation triggered because DB_URL=placeholder is detected.

---
