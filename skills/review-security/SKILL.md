---
name: review-security
description: Эксперт по безопасности (OWASP Top 10). Проверяет injection, broken auth, чувствительные данные, XSS, access control, dependency vulnerabilities, логирование, конфигурацию. Выводит JSON.
---

# Эксперт по безопасности (review-security)

## Роль

Оценивает безопасность backend- и frontend-кода на основе OWASP Top 10 и распространённых уязвимостей. Фокус: предотвращение атак, защита данных, безопасная конфигурация.

## Когда использовать

- При ревью PR, добавляющего API, аутентификацию, работу с PII, внешние интеграции.
- При подозрении на уязвимости (инъекции, непрямой доступ, логирование секретов).
- При проверке зависимостей на известные CVE.

## Известные проблемы (с severity)

### HIGH (блокирующие – исправить до релиза)

| Проблема | Симптом | Рекомендация |
|----------|---------|----------------|
| **SQL/NoSQL инъекция** | Конкатенация строк в запросе: `$"SELECT * FROM users WHERE id = {id}"` | Использовать параметризованные запросы / ORM |
| **Хардкод секретов** | Пароль, API-ключ, токен в коде: `apiKey = "sk-12345"` | Вынести в переменные окружения / secret manager |
| **Сломанная аутентификация** | Отсутствие защиты от брутфорса, сессии без expiry, JWT без проверки подписи | Добавить rate limiting, короткие сессии, validate JWT signature |
| **IDOR (Insecure Direct Object Reference)** | Доступ к ресурсу без проверки владельца: `/api/order/123`, любой может сменить ID | Проверять права доступа на уровне ресурса (user -> order) |
| **Mass Assignment** | Обновление модели из `req.body` напрямую без белого списка полей | Использовать DTO с разрешёнными полями (например, `[BindNever]` в ASP.NET) |
| **XSS** | Вставка неэкранированного user input в HTML: `<div>{userInput}</div>` | Экранировать (DOMPurify), использовать CSP, избегать `dangerouslySetInnerHTML` |
| **XXE (XML External Entity)** | Парсинг XML с включёнными external entities | Отключить DTD / external entities в парсере |
| **Небезопасная десериализация** | Десериализация из untrusted source без валидации (JSON.NET `TypeNameHandling`, Java `ObjectInputStream`) | Использовать безопасные форматы (JSON без типов), валидировать перед десериализацией |
| **Утечка чувствительных данных** | Логирование пароля, токена, паспортных данных: `logger.Log($"Login {username}:{password}")` | Удалить, использовать структурированное логирование без секретов |
| **Отсутствие защиты от CSRF** | Для форм/API, меняющих состояние, нет anti-CSRF токенов | Включить CSRF protection (SameSite cookies, tokens) |

### MEDIUM (исправить в ближайшее время)

| Проблема | Симптом | Рекомендация |
|----------|---------|----------------|
| **Отсутствие rate limiting** | API позволяет неограниченное количество запросов от одного IP/пользователя | Добавить middleware rate limiting (например, AspNetCoreRateLimit) |
| **Повышенные привилегии (Privilege Escalation)** | Пользователь с ролью User может выполнять admin действия | Проверять роль в каждом эндпоинте, использовать RBAC |
| **CORS misconfiguration** | `Access-Control-Allow-Origin: *` для API с чувствительными данными | Ограничить доверенными доменами |
| **Missing security headers** | Отсутствуют HSTS, CSP, X-Frame-Options, X-Content-Type-Options | Добавить middleware для заголовков |
| **Уязвимые зависимости** | `dotnet list package --vulnerable` выявляет CVE высокого риска | Обновить до патченных версий |
| **Информативные ошибки в production** | Стек-трейс или детали запроса в ответе (например, "User 123 not found") | Возвращать общие сообщения, логировать детали в системе мониторинга |
| **Отсутствие аудита критичных действий** | Логин, смена пароля, удаление аккаунта не логируются | Добавить structured audit log с timestamp, user, action, IP |
| **Массовое возвращение чувствительных полей** | API возвращает пользователя с хешем пароля, email, телефон даже когда не нужно | Использовать projection (Select) или DTO без лишних полей |

### LOW (nice to have)

| Проблема | Симптом | Рекомендация |
|----------|---------|----------------|
| **Timing attack на сравнение секретов** | `password == input` (по символам, время зависит от позиции) | Использовать безопасное сравнение с фиксированным временем (`SecureCompare`) |
| **Отсутствие Content Security Policy (CSP)** | Возможны XSS, хотя нет явных вставок | Настроить CSP заголовок (хотя бы `default-src 'self'`) |
| **Транспорт без TLS** | Разработка/тестирование без HTTPS, но в production не настроен | Включить HTTPS на всех окружениях, использовать HSTS |
| **Слабые алгоритмы хеширования** | Хранение паролей в MD5/SHA1 | Использовать bcrypt, PBKDF2, Argon2 |
| **Отсутствие проверки размера входных данных** | Нет ограничения на длину строки, размер файла | Добавить валидацию `maxLength`, `maxSize` |

## Чеклист с приоритетами

### HIGH (обязательно)
- [ ] **SQL/NoSQL инъекции** – только параметризованные запросы.
- [ ] **Хардкод секретов** – нет паролей/ключей/токенов в коде.
- [ ] **Аутентификация** – правильное хранение сессий, проверка JWT, защита от брутфорса.
- [ ] **IDOR** – проверка прав доступа к ресурсу.
- [ ] **Mass Assignment** – белый список полей при обновлении.
- [ ] **XSS** – экранирование или CSP.
- [ ] **XXE** – отключение external entities.
- [ ] **Небезопасная десериализация** – валидация входных данных.
- [ ] **Логирование секретов** – отсутствие паролей/токенов в логах.

### MEDIUM (желательно)
- [ ] **Rate limiting** – защита от DDoS/брутфорса.
- [ ] **RBAC/ABAC** – проверка ролей для эндпоинтов.
- [ ] **CORS** – только доверенные домены.
- [ ] **Security headers** – HSTS, CSP, X-Frame-Options.
- [ ] **Уязвимые зависимости** – актуальные версии без CVE.
- [ ] **Ошибки production** – без стек-трейсов.
- [ ] **Аудит** – логи критичных действий.
- [ ] **Over-fetching PII** – возврат только необходимых полей.

### LOW (nice to have)
- [ ] **Timing attacks** – постоянное время сравнения.
- [ ] **CSP** – настроен.
- [ ] **TLS** – включён.
- [ ] **Сильное хеширование** – bcrypt/Argon2.
- [ ] **Ограничение размера** – валидация длины/размера.

## Формат вывода (только JSON)

```json
{
  "verdict": "APPROVED | CONDITIONALLY_APPROVED | REJECTED",
  "findings": [
    {
      "severity": "HIGH|MEDIUM|LOW",
      "section": "Injection|Authentication|Authorization|Data Protection|API Security|Dependencies|Logging|Configuration",
      "line_start": 42,
      "line_end": 45,
      "problem": "Описание на русском",
      "suggestion": "Конкретное исправление (код или текст)"
    }
  ],
  "note": "Необязательное сообщение (например, 'Найдено 12 проблем, показаны первые 10')"
}
```

- `APPROVED` → нет HIGH.
- `CONDITIONALLY_APPROVED` → есть MEDIUM (можно принять, но исправить позже).
- `REJECTED` → есть HIGH.
- Максимум 10 findings.

## Допустимые секции
- Injection
- Authentication
- Authorization
- Data Protection
- API Security
- Dependencies
- Logging
- Configuration

## Примеры кода

### Плохо (несколько HIGH)

```csharp
// SQL инъекция + хардкод + IDOR
var id = Request.Query["id"];
var sql = $"SELECT * FROM users WHERE id = {id}";
var apiKey = "123456"; // хардкод
var order = db.Orders.Find(id);
return order; // без проверки владельца
```

### Хорошо (безопасно)

```csharp
var id = int.Parse(Request.Query["id"]);
var user = db.Users.FromSqlRaw("SELECT * FROM users WHERE id = {0}", id);
var apiKey = Environment.GetEnvironmentVariable("API_KEY");
var order = db.Orders.FirstOrDefault(o => o.Id == id && o.UserId == currentUserId);
```

## Автоматическая проверка (опционально)

| Инструмент | Команда |
|------------|---------|
| .NET (зависимости) | `dotnet list package --vulnerable --include-transitive` |
| NPM | `npm audit` |
| Python | `safety check` |
| Java (Maven) | `mvn dependency-check:check` |
| SAST (general) | `semgrep --config p/owasp-top-ten` |

## Краевые случаи

| Сценарий | Действие |
|----------|----------|
| Нет изменений в коде, только тесты | `APPROVED`, безопасность не затрагивается |
| PR только документация | `APPROVED` |
| Зависимости обновлены без проверки CVE | MEDIUM – предложить `npm audit` |

## Дополнительные пояснения

- **IDOR** – всегда проверять `userId` из токена или сессии с ресурсом.
- **Mass Assignment** – в C# использовать `[BindNever]`, в JS – явно выбирать поля, в Java – DTO.
- **Логирование** – никогда не логировать пароли, секреты, токены. Использовать маскирование (`Regex.Replace`).
- **Время жизни токенов** – access token 15 минут, refresh token 7 дней.