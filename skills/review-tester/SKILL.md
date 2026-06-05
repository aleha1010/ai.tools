---
name: review-tester
description: Test quality reviewer. Examines test structure, naming, assertions, mocks, coverage, maintainability, and business logic alignment.
---

# Test Quality Reviewer

## Known Problems (Test Smells)

### HIGH Severity

| Test Smell | Симптом | Recommendation |
|------------|---------|----------------|
| **No assertions** | Test has Act but no Assert | Добавить assertions, проверяющие business outcome |
| **Test interdependence** | Tests share state, order matters | Изолировать тесты, использовать fresh fixtures |
| **Under-mocking** | Real database/API calls in unit tests | Мокать внешние зависимости |
| **Mystery guest** | Test uses external resource without setup | Явный setup test data |
| **Wrong mock interface** | Mock не тот интерфейс, что в реализации | Синхронизировать с реализацией |

### MEDIUM Severity

| Test Smell | Симптом | Recommendation |
|------------|---------|----------------|
| **Wrong assertions** | Assert.Same для byte[] вместо Assert.Equal | Использовать правильный assertion type |
| **Over-mocking** | Mocking value objects, simple classes | Мокать только внешние зависимости |
| **Brittle tests** | Tests break on internal refactors | Тестировать behavior, не implementation |
| **Slow tests** | Unit tests take > 100ms each | Оптимизировать или переместить в integration tests |

### LOW Severity

| Test Smell | Симптом | Recommendation |
|------------|---------|----------------|
| **Magic test data** | Hardcoded values without explanation | Использовать константы с понятными именами |
| **Assertion roulette** | Multiple assertions without clear focus | Группировать в single logical assertion |
| **Test code duplication** | Copy-paste test setup | Extract helper methods |
| **Hardcoded secrets** | Passwords, API keys in test code | Использовать secret manager или test-specific secrets |

## Checklist

### Test Structure

- [ ] **AAA Pattern**: Arrange-Act-Assert sections clearly separated?
- [ ] **Single Responsibility**: One test = one behavior/concept?
- [ ] **Test Independence**: No shared state between tests?
- [ ] **Test Isolation**: Proper mocks/stubs, no external dependencies?

### Test Naming

- [ ] **Convention**: Follows project convention (e.g., `{MethodName}_{Scenario}_{ExpectedResult}`)?
- [ ] **Descriptive**: Name explains what is being tested without reading code?
- [ ] **Consistent**: Same naming pattern across test class?

### Test Data

- [ ] **Test Data Setup**: Clear, minimal, focused on scenario?
- [ ] **No Magic Numbers**: Constants/variables with descriptive names?
- [ ] **Edge Cases**: Boundary values, null, empty, invalid inputs covered?
- [ ] **Test Data Builders**: Use builders for complex test data?

### Assertions

- [ ] **Correct Assertion Types**: `Assert.Equal` vs `Assert.Same` vs `Assert.NotNull` appropriate?
- [ ] **No Missing Assertions**: Every test has assertions?
- [ ] **Assertion Quality**: Checks actual behavior/outcome, not implementation details?
- [ ] **Single Logical Assertion**: Multiple asserts OK if testing one concept?

### Mocks/Stubs

- [ ] **Mock Necessity**: Only external dependencies mocked (not internals)?
- [ ] **Mock Setup**: Correct method signatures, parameter matchers?
- [ ] **Mock Returns Business-Meaningful Data**: Test data reflects real business scenarios?
- [ ] **Mock Verification**: Verify calls only when behavior matters?
- [ ] **No Over-Mocking**: Not mocking value objects or simple classes?

### Coverage

- [ ] **Happy Path**: Main success scenario tested?
- [ ] **Error Paths**: Exception/error cases tested?
- [ ] **Edge Cases**: Boundary conditions tested?
- [ ] **Code Coverage**: ≥ 80% (automated check below)?

### Maintainability

- [ ] **DRY Principle**: No duplication in test code?
- [ ] **Helper Methods**: Shared test logic extracted?
- [ ] **Test Fragility**: Tests not brittle (survive internal refactors)?
- [ ] **Readability**: Tests read like documentation/specification?

### Security-Aware Testing

- [ ] **No Sensitive Data in Tests**: No hardcoded passwords, API keys, tokens in test code?
- [ ] **Security Tests Exist**: Auth, input validation, injection tests present where applicable?
- [ ] **Test Data Sanitization**: Test data does not contain real PII/credentials?

**Note:** For security test **correctness**, use `review-security`. This role verifies test **mechanics** only.

### Business Logic Alignment

- [ ] **Test Reflects Business Requirement**: Test verifies real business behavior?
- [ ] **Mock Data Matches Business Reality**: Test data corresponds to business domain?
- [ ] **Edge Cases Match Business Domain**: Boundary values from business context?
- [ ] **Assertions Verify Business Outcome**: Checks business result, not implementation?

#### Business Logic Alignment Examples

**Good:**
- Mock returns realistic IBAN: `"DE89370400440532013000"` (business-meaningful)
- Assertion checks business outcome: `result.Status == ApprovalStatus.Approved`
- Edge case from business: `amount > MaxTransactionLimit`

**Bad:**
- Mock returns placeholder: `"test_iban"` (meaningless)
- Assertion checks implementation: `repository.Verify(x => x.Save(), Times.Once)`
- Edge case not from business: `amount = -999999` (unrealistic)

## Integration Boundary Examples

### Example 1: User Registration Test

| Роль | Что проверяет | Пример замечания |
|------|---------------|------------------|
| **review-analyst** | Business scenario covered | "Тест не покрывает случай дублирования email" |
| **review-architect-backend** | Dependency direction | "UserService не должен зависеть от EF DbContext напрямую" |
| **review-tester** | Test quality | "Assertion проверяет `Save()` вызов, а не бизнес-исход: `result.IsSuccess`" |
| **review-security** | Security correctness | "Пароль не должен логироваться в тесте" |

### Example 2: Mocking Test

```csharp
// Bad test (different roles will catch issues)
[Fact]
public void ProcessPayment_ShouldWork()
{
    // Arrange
    var mock = new Mock<IPaymentService>();
    mock.Setup(x => x.Charge(It.IsAny<decimal>())).Returns(true);
    var service = new PaymentProcessor(mock.Object, "test_key"); // security: hardcoded key

    // Act
    var result = service.Process(100m);

    // Assert
    mock.Verify(x => x.Charge(100m), Times.Once); // tester: проверяет implementation
}
```

| Роль | Замечание |
|------|-----------|
| **review-analyst** | "Тест не покрывает edge case: PaymentService.Charge возвращает false" |
| **review-architect-backend** | "IPaymentService должен быть в Domain, реализация в Infrastructure" |
| **review-tester** | "Assertion проверяет вызов метода, а не бизнес-исход: `result.Status == PaymentStatus.Success`" |
| **review-security** | "Hardcoded API key в тесте — использовать secret manager" |

### Example 3: Business Logic Alignment

```csharp
// Bad test (tester will catch)
[Fact]
public void ValidateIban_ShouldReturnTrue()
{
    var validator = new IbanValidator();
    var result = validator.Validate("test_iban"); // tester: не business-meaningful data
    Assert.True(result);
}

// Good test
[Fact]
public void ValidateIban_WithValidGermanIban_ShouldReturnTrue()
{
    var validator = new IbanValidator();
    var result = validator.Validate("DE89370400440532013000"); // realistic IBAN
    Assert.True(result.IsValid);
}
```

## When to Use

| Сценарий | Когда запускать | Что проверять |
|----------|-----------------|---------------|
| **Self-review перед commit** | После написания тестов | Checklist из SKILL.md |
| **Code review** | При ревью PR с тестами | Test smells, assertions, mocks |
| **Plan review** | При ревью плана с тестами | Coverage, edge cases alignment |
| **Automated coverage check** | При review плана или PR | Run coverage analysis, generate test stubs |
| **Refactor tests** | Перед рефакторингом тестов | Maintainability checklist |

### Workflow

```
1. Написать тест (используя tdd skill для process)
2. Прогнать self-review checklist (используя review-tester для quality gates)
3. Запустить тесты локально
4. Закоммитить
5. PR → code review (reviewer использует review-tester)
```

## Unit vs Integration Tests

| Критерий | Unit Tests | Integration Tests |
|----------|-----------|-------------------|
| **Mocks** | Обязательны для внешних зависимостей | Минимум моков, реальные сервисы |
| **Speed** | < 100ms каждый | Может быть медленными |
| **Isolation** | Полная изоляция | Изолированы от production, но не от test infrastructure |
| **Data** | In-memory, mocks | Test database, test queues |
| **Assertions** | Проверяют business outcome | Проверяют end-to-end outcome |

### Integration Tests Checklist

- [ ] **Test Infrastructure**: Testcontainers/Test database configured?
- [ ] **Data Cleanup**: Tests clean up data after execution?
- [ ] **Real Dependencies**: External services running (or mocked at network level)?
- [ ] **Timeout Handling**: Tests handle slow responses gracefully?

## Automated Coverage Check

### Prerequisites

- .NET 8 SDK installed
- Project has test projects configured
- Cobertura coverage format supported

### Workflow

1. **Identify changed files**
   ```bash
   git diff --name-only --diff-filter=M --diff-filter=A HEAD~1
   ```
   Filter: `*.cs` files only, exclude `*.Tests.cs` (test files themselves)

2. **Run tests with coverage**
   ```bash
   dotnet test EncashmentAPI.sln --collect:"XPlat Code Coverage" --results-directory ./coverage
   ```

3. **Parse coverage report**
   - Locate `coverage.cobertura.xml` in results directory
   - Parse XML to extract:
     - Line coverage percentage
     - Branch coverage percentage
     - Coverage by class/method
   - Filter to changed files only

4. **Evaluate coverage**
   - For each changed file:
     - Calculate: `(covered lines / total lines) * 100`
     - If coverage < 80%, identify uncovered methods

5. **Generate test stubs** (max 5 methods)
   - Read code of uncovered method
   - Analyze:
     - Method signature (parameters, return type)
     - Code branches (if/switch statements)
   - Generate stubs with AAA comments

### Coverage Report Structure

**Input:** Cobertura XML
```xml
<coverage line-rate="0.75" branch-rate="0.68">
  <packages>
    <package name="Encashment.Service.Application">
      <classes>
        <class name="EncashmentService" filename="Services/EncashmentService.cs" line-rate="0.45">
          <methods>
            <method name="CreateRequest" line-rate="0.0">
              <lines>
                <line number="45" hits="0" branch="true"/>
              </lines>
            </method>
          </methods>
        </class>
      </classes>
    </package>
  </packages>
</coverage>
```

**Output:** Structured JSON
```json
{
  "verdict": "REJECTED",
  "summary": {
    "lineCoverage": 75.5,
    "branchCoverage": 68.2,
    "threshold": 80,
    "passed": false
  },
  "changedFiles": [
    {
      "file": "Services/EncashmentService.cs",
      "lineCoverage": 45.0,
      "passed": false,
      "uncoveredMethods": [
        {
          "method": "CreateRequest",
          "lineCoverage": 0,
          "branches": 3
        }
      ]
    }
  ],
  "generatedTests": [
    {
      "file": "Services/EncashmentService.cs",
      "method": "CreateRequest",
      "testClass": "EncashmentServiceTests",
      "testStubs": [
        {
          "name": "CreateRequest_ValidInput_ShouldCreateRequest",
          "code": "[Fact]\npublic void CreateRequest_ValidInput_ShouldCreateRequest()\n{\n    // Arrange: Create valid RequestDto with required fields\n    // Act: Call CreateRequest method\n    // Assert: Verify result is not null and has correct properties\n}"
        },
        {
          "name": "CreateRequest_NullInput_ShouldThrowArgumentNullException",
          "code": "[Fact]\npublic void CreateRequest_NullInput_ShouldThrowArgumentNullException()\n{\n    // Arrange: null input\n    // Act & Assert: Verify ArgumentNullException is thrown\n}"
        }
      ]
    }
  ],
  "note": "Additional uncovered methods: Validate, Process, Cancel. Generate tests manually or reduce scope."
}
```

### Test Stub Generation Logic

**For each uncovered method (max 5):**

1. **Read method code**
   - Use Read tool to read file
   - Extract method body

2. **Analyze signature**
   - Parameters: type, name, nullable?
   - Return type: void, Task, T?
   - Exceptions declared?

3. **Analyze code branches**
   - Count `if` statements → generate +1 test case per branch
   - Count `switch` cases → generate +1 test case per case
   - Identify null checks → generate null test
   - Identify validation logic → generate invalid input test

4. **Generate test stubs**
   - Standard cases:
     - Happy path (valid input)
     - Null input (if applicable)
     - Invalid input (validation failure)
   - Branch-specific cases:
     - For each `if` branch: test case covering that branch
     - For each `switch` case: test case covering that case

**Example:**

```csharp
// Production code
public RequestResult CreateRequest(RequestDto request)
{
    if (request == null)
        throw new ArgumentNullException(nameof(request));
    
    if (!IsValidAmount(request.Amount))
        return RequestResult.Failed("Invalid amount");
    
    var entity = _repository.Create(request);
    return RequestResult.Success(entity.Id);
}
```

**Generated test stubs:**

```csharp
[Fact]
public void CreateRequest_ValidInput_ShouldCreateRequest()
{
    // Arrange: Create valid RequestDto with Amount > 0
    // Act: Call CreateRequest method
    // Assert: Verify result.IsSuccess and result.Id is returned
}

[Fact]
public void CreateRequest_NullInput_ShouldThrowArgumentNullException()
{
    // Arrange: null input
    // Act & Assert: Verify ArgumentNullException is thrown
}

[Fact]
public void CreateRequest_InvalidAmount_ShouldReturnFailed()
{
    // Arrange: Create RequestDto with Amount <= 0
    // Act: Call CreateRequest method
    // Assert: Verify result.IsFailed and error message contains "Invalid amount"
}
```

### Edge Cases

| Scenario | Action |
|----------|--------|
| No changed `.cs` files | Return `verdict: APPROVED`, skip coverage check |
| No test projects found | Return `verdict: ERROR`, message: "No test projects found" |
| Coverage report not found | Return `verdict: ERROR`, message: "Coverage report generation failed" |
| > 5 uncovered methods | Generate tests for first 5, list remaining in `note` field |
| File has 0% coverage | All methods in file are uncovered, generate tests |
| Partial coverage (50-79%) | Identify uncovered methods, generate tests |

## Example: Automated Coverage Check Usage

### Scenario

Developer changed `EncashmentService.cs` and created PR.

### Agent Workflow

1. **Agent calls review-tester role:**
   ```
   Task tool:
     subagent_type: "explore"
     prompt: "You are a Test Quality Reviewer. Run automated coverage check for changed files.
              
              Steps:
              1. Run git diff --name-only HEAD~1 to find changed files
              2. Run dotnet test with coverage collection
              3. Parse coverage.cobertura.xml
              4. Check coverage for each changed file
              5. Generate test stubs for uncovered methods (max 5)
              
              Return structured JSON result."
   ```

2. **Agent analyzes result:**
   - If `verdict: APPROVED`, coverage check passed
   - If `verdict: REJECTED`, agent reads `generatedTests` and implements tests

3. **Agent implements tests:**
   - Read generated stubs
   - Implement test logic based on AAA comments
   - Run tests to verify they pass
   - Commit changes

### Example Output

```json
{
  "verdict": "REJECTED",
  "summary": {
    "lineCoverage": 45.0,
    "threshold": 80,
    "passed": false
  },
  "changedFiles": [
    {
      "file": "src/Encashment.Service.Application/Services/EncashmentService.cs",
      "lineCoverage": 45.0,
      "uncoveredMethods": ["CreateRequest", "Validate", "Process"]
    }
  ],
  "generatedTests": [
    {
      "file": "src/Encashment.Service.Application/Services/EncashmentService.cs",
      "method": "CreateRequest",
      "testClass": "EncashmentServiceTests",
      "testStubs": [
        {
          "name": "CreateRequest_ValidInput_ShouldCreateRequest",
          "code": "[Fact]\npublic void CreateRequest_ValidInput_ShouldCreateRequest()\n{\n    // Arrange: Create valid RequestDto\n    // Act: Call CreateRequest method\n    // Assert: Verify result is success\n}"
        },
        {
          "name": "CreateRequest_NullInput_ShouldThrowException",
          "code": "[Fact]\npublic void CreateRequest_NullInput_ShouldThrowException()\n{\n    // Arrange: null input\n    // Act & Assert: Verify ArgumentNullException\n}"
        }
      ]
    }
  ],
  "note": "Additional uncovered methods: Validate, Process"
}
