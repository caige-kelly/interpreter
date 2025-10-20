
# Ripple

**A functional, pipeline-oriented language with explicit error handling**

Ripple reimagines error handling by making failures a first-class part of your program's flow. Write clean, composable pipelines where errors propagate naturally—no try/catch blocks, no exception gymnastics.

## Why Ripple?

```ripple
// Traditional approach: error handling obscures logic
try {
  const data = await fetch(url);
  const parsed = JSON.parse(data);
  const validated = validate(parsed);
  return validated;
} catch (e) {
  logger.error(e);
  return defaultValue;
}

// Ripple: errors flow through pipelines naturally
data :=
  @Net.get url
    |> @Map.parse _
    |> @Map.validate schema _
    |> tap err(msg, _) -> @Log.error msg
    or default_value
```

## Core Philosophy

**No if/else.** Pattern matching via `match` expressions.

**No boolean operators.** Match expressions replace complex boolean logic.

**Explicit error handling.** Choose monadic (`@`) or tolerant (`#`) semantics at the call site.

**Immutable by default.** Rebinding creates new bindings; no reassignment.

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

#### Monadic (`@`): Explicit Error Handling

```ripple
// Expose both success and error channels
response := @Net.get "https://api.example.com/data"

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
temperature |> match t ->
  60 <= t <= 80 -> "comfortable"
  t < 60 -> "cold"
  any -> "hot"

// On Result types
@fetch_user(id) |> match ->
  ok(data, meta) -> data
  err(msg, meta) -> none
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
- **No boolean operators** - Match handles complex logic
- **No exceptions** - Errors are values in Result types
- **No variable shadowing** - Different values need different names
- **No reassignment** - Rebinding creates new bindings
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

## Example: Real-World Pipeline

```ripple
@deploy_service := config_path ->
  config :=
    @File.read config_path
      |> @Map.parse _
      |> @Map.validate deployment_schema _
      |> tap err(msg, _) ->
           @Slack.post ("Invalid config: " + msg)

  config |> match ->
    ok(data, _) ->
      @Net.post "https://deploy.example.com/api" data
        |> tap ok(_, meta) ->
             @Log.info ("Deployed in " + meta.duration)
        |> tap err(msg, _) ->
             @Slack.post ("Deploy failed: " + msg)
    err(msg, _) ->
      err("Configuration invalid: " + msg)

// Caller chooses: handle errors explicitly or fail gracefully
result := @deploy_service "./config.json"  // Monadic
deployment := #deploy_service "./config.json" or none  // Tolerant
```

## Learn More

- **Reference Script**: `docs/reference.ripple` - Complete language specification
- **Handoff Document**: `docs/handoff.md` - Implementation details and roadmap
- **Design Philosophy**: See "Why No If/Else?" and "@ vs # Domains" sections

## License

[To be determined]

---

**Ripple**: Making errors flow naturally through your code.
