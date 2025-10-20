# Ripple

**A functional, pipeline-oriented language with explicit error handling**

Ripple reimagines error handling by making failures a first-class part of your program's flow. Write clean, composable pipelines where errors propagate naturally—no try/catch blocks, no exception gymnastics.

## Why Ripple?

```python
# Python: Error handling obscures the business logic
def load_config(path):
    try:
        with open(path, 'r') as f:
            config = json.load(f)
            if not validate_config(config):
                return None
            return config
    except FileNotFoundError:
        print(f"Config not found: {path}")
        return None
    except json.JSONDecodeError as e:
        print(f"Invalid JSON: {e}")
        return None

config = load_config('./config.json')
if config is None:
    config = default_config
```

```ripple
// Ripple: The happy path is the code, errors flow naturally
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

// Multi-line
process := x ->
  y := x + 1
  z := y * 2
  z                        // Implicit return
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

**Python version with nested try/catch:**
```python
def deploy_to_server(server, user, app_name, version):
    try:
        # Stop service
        result = subprocess.run(
            f"ssh {user}@{server} 'sudo systemctl stop {app_name}'",
            capture_output=True, timeout=30
        )
        if result.returncode != 0:
            return False, f"Stop failed: {result.stderr}"
        
        # Copy files
        result = subprocess.run(
            f"scp ./dist/{app_name}-{version}.tar.gz {user}@{server}:/tmp/",
            capture_output=True, timeout=30
        )
        if result.returncode != 0:
            return False, f"Copy failed: {result.stderr}"
        
        # Extract and start
        # ... more nested error checking
        
        return True, None
    except subprocess.TimeoutExpired:
        return False, "Command timed out"
    except Exception as e:
        return False, f"Unexpected error: {e}"
```

**Ripple version with explicit error flow:**
```ripple
@deploy_to_server := server user app_name version ->
  commands := [
    "ssh " + user + "@" + server + " 'sudo systemctl stop " + app_name + "'",
    "scp ./dist/" + app_name + "-" + version + ".tar.gz " + user + "@" + server + ":/tmp/",
    "ssh " + user + "@" + server + " 'cd /opt/" + app_name + " && tar -xzf /tmp/" + app_name + "-" + version + ".tar.gz'",
    "ssh " + user + "@" + server + " 'sudo systemctl start " + app_name + "'",
  ]
  
  commands
    |> @List.fold_until none (acc, cmd ->
         @Process.run cmd {timeout: 30}
           |> match ->
                ok(result, _) ->
                  result.exit_code == 0 |> match ->
                    true -> {continue: none}
                    false -> {stop: err("Command failed: " + cmd + "\n" + result.stderr)}
                err(msg, _) ->
                  {stop: err("Command error: " + cmd + "\n" + msg)}
       )
```

**Health check with retry logic:**
```python
# Python: Manual retry loop with state
def wait_for_healthy(server, health_url, max_retries=10):
    for attempt in range(max_retries):
        try:
            response = requests.get(f"http://{server}{health_url}", timeout=5)
            if response.status_code == 200:
                data = response.json()
                if data.get('status') == 'healthy':
                    return True, None
        except:
            pass
        
        if attempt < max_retries - 1:
            time.sleep(3)
    
    return False, "Server did not become healthy"
```

```ripple
// Ripple: Recursive with explicit state
@wait_for_healthy := server health_url max_retries ->
  @wait_helper server health_url max_retries 0

@wait_helper := server health_url max_retries attempt ->
  attempt < max_retries |> match ->
    false -> 
      err("Server did not become healthy after " + max_retries + " attempts")
    true ->
      @check_health server health_url |> match ->
        ok(_, _) -> 
          ok(none)
        err(msg, _) ->
          attempt < (max_retries - 1) |> match ->
            true ->
              @Time.sleep 3000
              @wait_helper server health_url max_retries (attempt + 1)
            false ->
              err("Timeout: " + msg)

@check_health := server health_url ->
  @Net.get ("http://" + server + health_url) {timeout: 5}
    |> @Map.parse_json _
    |> match ->
         ok(data, _) ->
           data.status == "healthy" |> match ->
             true -> ok(none)
             false -> err("Server reports: " + data.status)
         err(msg, _) ->
           err("Health check failed: " + msg)
```

**Configuration validation:**
```python
# Python: Imperative checks with early returns
def validate_config(config):
    required = ['servers', 'app_name', 'deploy_user', 'health_check_url']
    
    for field in required:
        if field not in config:
            print(f"Missing field: {field}")
            return False
    
    if not config['servers']:
        print("No servers specified")
        return False
    
    return True
```

```ripple
// Ripple: Functional validation with descriptive errors
@validate_config := config ->
  required := ["servers", "app_name", "deploy_user", "health_check_url"]
  
  missing :=
    required
      |> #List.filter (field -> (#Map.get config field) == none)
  
  (#List.is_empty missing) |> match ->
    false ->
      err("Missing required fields: " + (#String.join missing ", "))
    true ->
      (#List.is_empty config.servers) |> match ->
        true -> err("No servers specified")
        false -> ok(config)
```

## Learn More

- **Reference Script**: `docs/reference.ripple` - Complete language specification
- **Handoff Document**: `docs/handoff.md` - Implementation details and roadmap
- **Design Philosophy**: See "Why No If/Else?" and "@ vs # Domains" sections

## License

[To be determined]

---

**Ripple**: Making errors flow naturally through your code.
