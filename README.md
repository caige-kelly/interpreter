# Ripple

**A functional, pipeline-oriented language with explicit error handling**

Ripple reimagines error handling by making failures a first-class part of your program's flow. Write clean, composable pipelines where errors propagate naturally—no try/catch blocks, no exception gymnastics.

## Why Ripple?

```python
# Python: Exceptions separate error handling from logic
from pathlib import Path
import json

def load_config(path):
    """Most Pythonic: let exceptions propagate, handle at boundary"""
    config = json.loads(Path(path).read_text())
    validate_config(config)
    return config

# At call site - error handling separated from happy path
try:
    config = load_config('./config.json')
except (FileNotFoundError, json.JSONDecodeError, ValueError):
    config = default_config
```

```ripple
// Ripple: Errors flow inline with logic
config :=
  #File.read "./config.json"
    |> #Map.parse_json _
    |> #validate_config _
  or default_config
```

## Core Philosophy

**No if/else.** Pattern matching via `match` expressions.

**Boolean operators for guards.** `&&` and `||` compose conditions in match patterns and predicates, not for control flow.

**Explicit error handling.** Choose monadic (`@`) or tolerant (`#`) semantics at the call site.

**Immutable. No rebinding.** Once bound, names cannot be reused—use pipelines for transformations.

**Pipelines first.** Data flows through transformations via `|>`.

## Quick Tour

### Variables & Types

```ripple
x := 42                    // Type inferred
name := "alice"            // Immutable by default
active := true
nothing := none

// No shadowing allowed - use pipelines instead
result := 1
  |> (_ + 1)               // 2
  |> (_ * 2)               // 4
```

### Functions

```ripple
// Everything is a lambda bound to a name
add := a, b -> a + b
result := add 10 32        // 42

// Multi-line (implicit return of last expression)
process := x ->
  y := x + 1
  y * 2
```

### Pipelines

```ripple
result :=
  "hello world"
    |> #String.uppercase _
    |> #String.split " "
    |> #List.map (word -> word + "!")
```

### Error Handling: Choose Your Semantics

Ripple's killer feature: **caller-driven error interpretation**. The same function can be used monadically (explicit error handling) or tolerantly (fail gracefully).

**Critical: Unhandled Result types halt compilation.** You must explicitly handle errors through pattern matching, convert to tolerant mode with `#`, or propagate them upward.

#### Monadic (`@`): Explicit Error Handling

```ripple
// Expose both success and error channels
response := @Net.get "https://api.example.com/data"

// MUST handle the Result - compilation fails otherwise
response |> match ->
  ok(body, meta) ->
    #IO.stdout ("Success: " + body)
  err(msg, meta) ->
    @Slack.post ("Error: " + msg)
```

#### Tolerant (`#`): Graceful Fallback

```ripple
// Collapse errors to none, provide fallback
config :=
  #File.read "./config.json"
    |> #Map.parse _
  or #Map.new { env: "dev" }

// No explicit error handling needed - errors become none
```

### Result Type: Dual Channel Architecture

```ripple
Result<V, E, S> = ok(V, S) | err(E, S)
```

**Two channels:**
- **User channel:** `V` or `E` - your semantic value
- **System channel:** `S` - metadata (duration, retries, status)

### Pattern Matching

No `if/else` statements. Use `match` for all conditional logic:

```ripple
// Health check responses
response := @check_health server health_url

response |> match ->
  ok(data, meta) ->
    @IO.stdout ("Server healthy - responded in " + meta.duration + "ms")
  err(msg, meta) ->
    @Slack.post ("Health check failed: " + msg)

// Guards compose conditions with && and ||
user |> match u ->
  u.age >= 18 && u.has_license -> 
    @grant_access u
  u.age >= 16 && u.has_permit -> 
    @grant_supervised_access u
  any -> 
    @deny_access u

// Deployment result handling
deployment_result |> match ->
  ok(servers, _) ->
    @IO.stdout ("Deployed to " + (#String.join servers ", "))
  err(failure, _) ->
    @IO.stderr ("Failed at server: " + failure.server)
    @rollback failure.deployed_servers
```

### Side Effects with `tap`

Observe values in a pipeline without changing them:

```ripple
result :=
  @Net.post url payload
    |> tap err(msg, _) ->
         @Slack.post ("Failed: " + msg)
    |> @Map.parse _
  or default_response
```

## Language Design

### What's Different

- **No `if/else`** - Pattern matching replaces conditionals
- **No exceptions** - Errors are values in Result types
- **No variable shadowing** - Once bound, a name cannot be reused
- **No reassignment** - All values are immutable
- **Parentheses only for grouping** - Not for function calls

### Operator Overview

| Operator | Purpose | Example |
|----------|---------|---------|
| `\|>` | Pipeline forward | `data \|> process \|> save` |
| `or` | Fallback on none | `#File.read path or default` |
| `then` | Sequence (only if left not none) | `#File.read path then #Map.parse _` |
| `tap` | Side effects | `result \|> tap err -> #Log.error _` |
| `match` | Pattern matching | `value \|> match -> ...` |

## Current Status

**Phase 1: Foundation** ✅ Complete
- Lexer, parser, evaluator functional
- 56 tests passing, zero memory leaks
- Arithmetic, comparisons, strings working
- Clean functional architecture

**Phase 2: Core Features** 🔨 In Progress
- Functions and lambdas
- Lists and maps
- Pipeline operator
- Pattern matching

**Phase 3: Error Handling** ⏳ Designed
- Result type implementation
- `@` vs `#` domain markers
- `or`, `then`, `tap` operators

## Building & Testing

```bash
# Run all tests
zig build test

# With detailed output
zig build test --summary all

# Run specific component tests
zig test src/evaluator.zig
```

## Project Structure

```
ripple/
├── src/
│   ├── lexer.zig          # Tokenization (functional)
│   ├── parser.zig         # Precedence climbing parser (functional)
│   ├── evaluator.zig      # Type-aware evaluation (functional)
│   ├── supervisor.zig     # Execution orchestration
│   ├── ast.zig            # Abstract syntax tree
│   └── error.zig          # Error reporting
├── docs/
│   ├── reference.ripple   # Language reference (v5.0)
│   └── handoff.md         # Project documentation (v2.0)
└── build.zig              # Zig build configuration
```

## Philosophy: Language + IDE Partnership

Ripple's syntax is intentionally clean (like Python). Type rigor and semantic clarity come from IDE tooling (like Haskell):

- **Hover** to see inferred types
- **IDE marks** `@` functions differently from `#` functions
- **Inline hints** reveal the type system
- **Verbose tracing** available via IDE plugin

Best of both worlds: Python's readability + Haskell's type safety.

## Contributing

Ripple is in active development. We're currently implementing core language features using TDD (Test-Driven Development).

Current focus areas:
- Function definition and calls
- Collection types (lists, maps)
- Pipeline operator implementation
- Pattern matching

## Example: Real-World Deployment Script

**Python - idiomatic with exception handling:**
```python
import subprocess
from typing import List

def deploy_to_server(server: str, user: str, app_name: str, version: str):
    """Pythonic: raise on error, handle at boundary"""
    commands = [
        f"ssh {user}@{server} 'sudo systemctl stop {app_name}'",
        f"scp ./dist/{app_name}-{version}.tar.gz {user}@{server}:/tmp/",
        f"ssh {user}@{server} 'cd /opt/{app_name} && tar -xzf /tmp/{app_name}-{version}.tar.gz'",
        f"ssh {user}@{server} 'sudo systemctl start {app_name}'",
    ]
    
    for cmd in commands:
        subprocess.run(
            cmd, 
            shell=True, 
            check=True,  # Raises CalledProcessError on failure
            capture_output=True, 
            timeout=30
        )

# Usage: error handling is distant from execution
try:
    deploy_to_server(server, user, app_name, version)
    print(f"✓ Deployed to {server}")
except subprocess.CalledProcessError as e:
    print(f"Command failed: {e.stderr.decode()}")
    rollback(server)
except subprocess.TimeoutExpired:
    print("Deployment timed out")
    rollback(server)
```

**Ripple - errors flow with logic:**
```ripple
@deploy_to_server := server user app_name version ->
  [
    -> @Process.run ("ssh " + user + "@" + server + " 'sudo systemctl stop " + app_name + "'") {timeout: 30},
    -> @Process.run ("scp ./dist/" + app_name + "-" + version + ".tar.gz " + user + "@" + server + ":/tmp/") {timeout: 30},
    -> @Process.run ("ssh " + user + "@" + server + " 'cd /opt/" + app_name + " && tar -xzf /tmp/" + app_name + "-" + version + ".tar.gz'") {timeout: 30},
    -> @Process.run ("ssh " + user + "@" + server + " 'sudo systemctl start " + app_name + "'") {timeout: 30},
  ]
    |> @List.try_sequence _

// Usage: error handling flows inline
@deploy_to_server server user app_name version
  |> match ->
       ok(_, _) -> @IO.stdout ("✓ Deployed to " + server)
       err(msg, _) ->
         @IO.stderr msg
         @rollback server
```

**Health check with retry logic:**
```python
import requests
import time

def wait_for_healthy(server: str, health_url: str, max_retries: int = 10) -> None:
    """Pythonic: raise on final failure"""
    for attempt in range(max_retries):
        try:
            response = requests.get(f"http://{server}{health_url}", timeout=5)
            response.raise_for_status()
            
            if response.json().get('status') == 'healthy':
                return  # Success
                
        except (requests.RequestException, ValueError):
            if attempt == max_retries - 1:
                raise  # Re-raise on final attempt
            time.sleep(3)
    
    raise TimeoutError(f"Server {server} did not become healthy")

# Usage
try:
    wait_for_healthy(server, health_url)
    print("Server healthy")
except (requests.RequestException, TimeoutError) as e:
    print(f"Health check failed: {e}")
```

```ripple
// Ripple: Retry logic as a task combinator
@wait_for_healthy := server health_url max_retries ->
  check := ->
    data := @Net.get ("http://" + server + health_url) {timeout: 5}
      |> @Map.parse_json _
    @Result.ensure data (d -> d.status == "healthy") "Server not healthy"
  
  @Task.retry check {max_attempts: max_retries, delay: 3000}

// Usage: inline error handling
@wait_for_healthy server health_url 10
  |> match ->
       ok(_, _) -> @IO.stdout "Server healthy"
       err(msg, _) -> @IO.stderr ("Health check failed: " + msg)
```

**Configuration validation:**
```python
def validate_config(config: dict) -> dict:
    """Pythonic: raise descriptive errors"""
    required = ['servers', 'app_name', 'deploy_user', 'health_check_url']
    
    missing = [field for field in required if field not in config]
    if missing:
        raise ValueError(f"Missing required fields: {', '.join(missing)}")
    
    if not config['servers']:
        raise ValueError("No servers specified")
    
    return config

# Usage: try/except at boundary
try:
    config = validate_config(raw_config)
except ValueError as e:
    print(f"Invalid config: {e}")
    sys.exit(1)
```

```ripple
// Ripple: Return Result type, compose naturally
@validate_config := config ->
  required := ["servers", "app_name", "deploy_user", "health_check_url"]
  missing := required
    |> #List.filter (field -> (#Map.get config field) == none)
  
  (#List.is_empty missing) |> match ->
    false -> err("Missing required fields: " + (#String.join missing ", "))
    true ->
      (#List.is_empty config.servers) |> match ->
        true -> err("No servers specified")
        false -> ok(config)

// Usage: compose with other operations
config :=
  @File.read path
    |> @Map.parse_json _
    |> @validate_config _
    |> match ->
         ok(c, _) -> c
         err(msg, _) ->
           @IO.stderr ("Invalid config: " + msg)
           @IO.exit 1
```

## Learn More

- **Reference Script**: `docs/reference.ripple` - Complete language specification
- **Handoff Document**: `docs/handoff.md` - Implementation details and roadmap
- **Design Philosophy**: See "Why No If/Else?" and "@ vs # Domains" sections

## License

[To be determined]

---

**Ripple**: Making errors flow naturally through your code.
