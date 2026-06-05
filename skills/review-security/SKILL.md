---
name: review-security
description: Security reviewer. Based on OWASP classification and known vulnerability patterns.
---

# Security Reviewer

## Classification (OWASP Top 10 + Common)

| Категория | Проблемы |
|-----------|----------|
| Injection | SQL, NoSQL, OS command, LDAP, XPath |
| Broken Auth | Session management, credentials, tokens |
| Sensitive Data | PII exposure, encryption, logging |
| XXE | XML parsing, external entities |
| Broken Access | IDOR, missing auth checks |
| Security Misconfig | Default creds, verbose errors, CORS |
| XSS | Reflected, stored, DOM-based |
| Insecure Deserialization | Object injection, type confusion |
| Known Vulnerabilities | CVE in dependencies |
| Insufficient Logging | Audit trails, monitoring |

## Checklist

- [ ] **Injection**: Все input параметризованы? Нет конкатенации в SQL/commands?
- [ ] **Authentication**: Credentials не хардкодятся? Tokens безопасно хранятся? Session expiry?
- [ ] **Authorization**: RBAC/ABAC реализован? Resource-level checks? Principle of least privilege?
- [ ] **Data Protection**: PII зашифрован? Secrets в секрет-менеджере? Logs не содержат sensitive data?
- [ ] **Input Validation**: Все input валидируются (type, length, format)? Sanitization для HTML/JSON?
- [ ] **API Security**: Rate limiting? Input size limits? CORS configured? Security headers?
- [ ] **Dependencies**: Нет CVE в зависимостях? Проверка через `dotnet list package --vulnerable`?
- [ ] **Error Handling**: Нет stack trace в production errors? Graceful degradation?
- [ ] **Logging**: Security events logged? Audit trail для критичных операций?
