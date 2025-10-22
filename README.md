# Ripple

⚠️ **Vision Document**: This README describes Ripple’s intended design and architecture. See [`docs/handoff.md`](docs/handoff.md) for current implementation status.

**Current Status**: Phase 1 complete (lexer, parser, evaluator - 56 tests passing). Phase 2 in progress (functions, collections, pipelines).

## Operational scripts that don’t lie about failures

Stop duct-taping together bash, Python, cron, systemd, and logging just to run reliable automation. Ripple is a functional, pipeline-oriented language designed specifically for operational scripts—with built-in scheduling, supervision, and observability.

-----

## The Problem

Every production system has operational scripts: database backups at 3am, multi-stage build pipelines, release automation, cleanup jobs, health checks. And they’re all held together with duct tape:

```bash
#!/bin/bash
set -e  # Pray nothing fails silently

# /etc/cron.d/backup
0 3 * * * /opt/scripts/backup.sh >> /var/log/backup.log 2>&1
```

```python
# backup.py - scattered across 5 different systems
import subprocess, logging, boto3
from apscheduler.schedulers.blocking import BlockingScheduler

@scheduler.scheduled_job('cron', hour=3)
def backup():
    databases = ['prod', 'staging', 'dev']
    failed = []
    for db in databases:
        try:
            subprocess.run(['pg_dump', db], check=True)
            # Upload to S3...
        except subprocess.CalledProcessError as e:
            failed.append(db)
            logging.error(f'{db} failed: {e}')
    
    if failed:
        # How do you know what succeeded?
        # How do you rollback partial failures?
        send_alert(f"Backup failed: {failed}")
```

You need 5 separate tools:

- **Cron** - scheduling
- **Systemd/supervisor** - process management
- **Python/bash** - the actual logic
- **Logging libraries** - observability
- **Monitoring/alerting** - know when things break

And none of them talk to each other.

-----

## The Solution

```ripple
// backup.rip - everything in one place
process::doc::header """
  Back up is designed to run every night at 3:00 am
  Logs are traced to s3://logs/ripple/
  The Ops distro is emailed on failure
"""
!system::schedule "0 3 * * *"
!system::trace_to "s3://logs/ripple/"
!system::on_failure email::configure(?email_config_map).send_body("Backups failed")
!process::timeout 600000

databases := ["prod", "staging", "dev"]
s3_url := "s3://backups"

process:doc::section "Backup Procedure """
  Retry the backups 3 times if there is failure.
  Sleep for 30 seconds inbetween incase there is a network issue or something odd happening

  Some older AMIs we still use for legacy have gzip.
  Newer AMIs, most systems, should have brotli now.
"""
!task::retry {max_retries: 3, sleep: 30s}
backup_db := db ->
  process::run ["pg_dump", db]
    |> dump -> process::run ["gzip", dump, ">", "backup.gz"] or process::run ["brotli", dump, ">", "backup.br"]
    |> s3::upload "{s3_url}/last_night_backups/{db}.zip" _

  // Equivalent 
  dump := process::run ["pg_dump", db]

  comp :=
    process::run ["gzip", dump, ">", "backup.gz"]
    or
    process::run ["brotli", dump, ">", "backup.br"]

  s3::upload "{s3_url}/last_night_backups/{db}.zip" comp

// Parallel execution, returns [Result, Result, Result]
results := ^databases.parallel_map backup_db, {max_concurrent: 3}

process::doc::section "Parse Results" """
  Partition results into successes and failures, then match on outcomes
  TODO: need to think of better error handling
"""
results |> list::partition [failure, success] |> match p ->
  p.failure.length == 0 ->
    io::stdout "✓ All " + p.success.length + " databases backed up"
  p.success.length == 0 ->
    sys::exit 1
  any ->
    p.failure |> map f -> io::stderr "Failed: " + f
```

```bash
# One command to deploy (planned)
rvm run backup.rip

# Built-in management (planned)
rvm list              # See all running scripts
rvm logs backup.rip   # View logs
rvm trace backup.rip  # See execution trace
rvm restart backup.rip # Graceful restart
```

-----

## Why Ripple?

### 1. Built-in Runtime Management

**Other languages:** You write the script, you figure out how to run it

**Ripple:** Configure the runtime once, it handles execution

```ripple
System.schedule = "0 3 * * *"      // Built-in cron
System.max_memory = "512MB"        // Resource limits
System.trace_to = "jaeger://traces" // Distributed tracing
System.on_failure = Alert.slack   // Failure hooks

Process.timeout = 600000           // Global timeout
Process.retries = 3                // Retry failed operations
Process.parallel_limit = 5         // Max concurrency

// Your script - runtime handles the rest
do_work()
```

No more writing timeout wrappers, implementing retry logic, or configuring process supervisors.

### 2. Errors Flow Inline With Your Logic

**Python:** Exceptions separate error handling from logic

```python
try:
    result1 = step1()
    result2 = step2(result1)
    result3 = step3(result2)
    return result3
except Exception as e:
    # What actually succeeded? ¯\_(ツ)_/¯
    rollback_somehow()
```

**Ripple:** Errors are values that flow through your code

```ripple
result := step1
  |> step2
  |> step3

match result ->
  ok(v) -> process v
  err(e) -> handle_error e
```

Choose your error semantics at the call site:

- **(default)** = Returns `Result<T, E>`, handle explicitly
- **`?`** = Optional: Returns `value | none`, use `or` for fallback
- **`!`** = Critical: Must succeed or crash
- **`^`** = Keep wrapped: Preserve Result for inspection

```ripple
config := ?file::read "config.json" or default_config  // Optional
critical := !file::read "required.json"                // Must succeed
result := ^database_query                              // Keep Result for matching
```

### 3. Automatic Observability

**Python:** Add logging manually everywhere

```python
logger.info("Starting step 1")
result1 = step1()
logger.info(f"Step 1 done in {duration}ms")
# ... repeat forever
```

**Ripple:** Every expression is automatically traced

```ripple
// Just write your logic
build_artifact "linux"
  |> sign
  |> upload_to "releases/"
```

```bash
# Automatic traces for every expression (planned)
rvm trace build.rip

# Output:
# [12:34:01.234] Line 5: build_artifact "linux"
#   -> ok("app-v1.0-linux", {duration: 2341ms, memory: 234MB})
# [12:34:03.575] Line 6: sign
#   -> ok("app-v1.0-linux.sig", {duration: 89ms})
# [12:34:03.664] Line 7: upload_to
#   -> err("network timeout", {duration: 1205ms, retries: 3})
```

Export traces anywhere:

```ripple
System.trace_to = "jaeger://localhost:6831"
System.trace_to = "datadog://api-key"
System.trace_to = "file:///var/log/ripple/"
```

### 4. Partial Success is First-Class

The killer feature for multi-stage operations.

**Python:** Track partial success manually

```python
succeeded = []
failed = []
for server in servers:
    try:
        deploy(server)
        succeeded.append(server)
    except Exception as e:
        failed.append((server, str(e)))

# Manually handle partial success
if failed:
    print(f"Deployed to: {succeeded}")
    print(f"Failed: {failed}")
    # Rollback? Which servers? How?
```

**Ripple:** Built into list operations

```ripple
servers := ["web-1", "web-2", "web-3"]
results := servers.parallel_map deploy, {max_concurrent: 3}

results |> list::partition [failure, success] |> match p ->
  p.failure.length == 0 ->
    io::stdout "✓ Deployed to all " + p.success.length + " servers"
  p.success.length == 0 ->
    !pagerduty::alert "✗ Deploy completely failed"
    !sys::exit 1
  any ->
    !slack::alert "⚠ Partial: " + p.success.length + " ok, " + p.failure.length + " failed"
    rollback p.success  // Rollback what succeeded
```

How it works:

- All operations return `Result<T, E>`
- `List.partition` separates successes from failures
- Match with guards checks all three outcomes
- Both lists available for processing/rollback

### 5. One CLI for Everything

**Other languages:** Figure out systemd/supervisor/cron yourself

**Ripple:** One CLI for everything (planned)

```bash
rvm run my_script.rip   # Run as daemon with supervision
rvm exec my_script.rip  # One-off execution

# See what's running
rvm list
# NAME          STATUS   LAST RUN              NEXT RUN
# backup.rip    running  2024-10-20 03:00:00   2024-10-21 03:00:00
# deploy.rip    idle     2024-10-19 14:32:15   manual
# cleanup.rip   failed   2024-10-20 01:00:00   2024-10-21 01:00:00

# Debug and manage
rvm logs backup.rip --follow
rvm trace backup.rip --expression 23
rvm restart backup.rip
```

-----

## Core Design Principles

- **No if/else** - Pattern matching via `match` expressions
- **Everything returns Result** - Explicit, traceable error handling
- **Immutable** - No variable shadowing, use pipelines for transformation
- **Pipelines first** - Data flows through transformations
- **Built-in observability** - Every expression traced automatically

-----

## Language Guide

### Everything is a Result

For cases where the piped value is not the first argument, an anonymous function must be used. 

This is the foundation of Ripple’s design. Every expression returns a `Result<T, E>`:

```ripple
5                // ok(5, metadata)
true             // ok(true, metadata)
"hello"          // ok("hello", metadata)
[]               // ok([], metadata)
add 2, 3         // ok(5, metadata)
divide 10, 0     // err("division by zero", metadata)
```

This unified model means:

- Errors are always tracked
- Every operation is automatically traced
- Success and failure flow through the same pipeline

### Assignment Unwraps by Default

For ergonomics, the assignment operator `:=` automatically unwraps Results:

```ripple
x := 5           // Assignment unwraps: x = 5 (not ok(5, meta))
y := x + 3       // Just works: y = 8
name := "Alice"  // name = "Alice"
```

This gives you clean, readable code without explicit unwrapping everywhere.

### The `^` Operator: Keep It Wrapped

Use `^` when you need to preserve the Result for inspection:

```ripple
result := ^database_query  // result = ok(...) or err(...)

match result ->
  ok(data, meta) -> 
    io::stdout "Query took " + meta.duration + "ms"
  err(e, meta) -> 
    alert "Failed after " + meta.retries + " retries: " + e
```

Without `^`, the assignment would unwrap it and you’d lose access to error details.

### Pipeline Policies

The symbols `!`, `?`, and `^` are **pipeline policies** - instructions that tell the evaluator how to process Results:

```ripple
// Default: Auto-unwrap in pipelines and assignment
x := operation         // Unwraps to value
operation |> process   // Unwraps for next step

// ^ = Keep wrapped (don't auto-unwrap)
x := ^operation        // x = Result<T, E>
^operation |> match -> // Match on Result structure
  ok(v) -> ...
  err(e) -> ...

// ! = Unwrap or panic (for critical operations)
x := !operation        // Panic if err
!operation |> process  // Pipeline panics on err

// ? = Unwrap or none (for optional operations)
x := ?operation or default   // Use default if err
?operation |> process        // Skip processing if err
```

### Policy Application Rules

Policies follow natural binding (right-to-left, closest to the Result):

```ripple
✅ x := operation       // Unwrap (default)
✅ x := ^operation      // Keep wrapped
✅ x := !operation      // Unwrap or panic
✅ x := ?operation      // Unwrap or none

❌ x := ?!operation     // Error: Multiple policies conflict
❌ x := ^?operation     // Error: Can't keep wrapped AND make optional
```

**Only one policy per Result.** Multiple policies are a compile error.

### Working with Wrapped Results

When you use `^` to keep a Result wrapped, you must explicitly unwrap it:

```ripple
result := ^get_data

// Option 1: Match on it
match result ->
  ok(v) -> process v
  err(e) -> handle e

// Option 2: Explicit unwrap with policy
value := !result       // Panic if err
value := ?result or default  // Use default if err
value := result.unwrap       // Explicit unwrap method

// Option 3: Use in pipeline (auto-unwraps)
result |> process      // Unwraps for pipeline
```

### Variables & Functions

```ripple
x := 42
add := a, b -> a + b
result := add 10, 32   // 42
```

Functions automatically return Results:

```ripple
divide := a, b ->
  match b ->
    0 -> err "division by zero"
    _ -> ok(a / b)

// At call site, choose your policy:
x := divide 10, 2       // x = 5 (unwrapped)
x := ^divide 10, 0      // x = err("division by zero", meta) (wrapped)
x := !divide 10, 2      // x = 5 or panic
x := ?divide 10, 2 or 0 // x = 5 or 0 if error
```

### Pipelines

Data flows left-to-right through transformations. Pipelines auto-unwrap Results:

```ripple
result := "hello world"
  |> string::uppercase      // Unwraps input, returns Result
  |> string::split " "      // Unwraps input, returns Result
  |> map word -> word + "!" // Unwraps input, returns Result
  |> list::join ", "        // Final Result
```

If any step returns an error, the pipeline short-circuits and returns that error.

### Method Chaining Through Results

This is one of Ripple’s most powerful features: **methods automatically operate on the value inside a Result**.

```ripple
x := ["hello", "world"]           // ok(["hello", "world"], meta)
value := x.get(0).uppercase       // ok("HELLO", meta)

// If any step fails, the chain short-circuits:
y := []                           // ok([], meta)
value := y.get(0).uppercase       // err("index out of bounds", meta)
                                  // .uppercase never runs
```

**How it works:**

When you call a method on a Result, the method operates on the *inner value* while preserving the Result wrapper:

```ripple
// Behind the scenes:
x = ok(["hello", "world"], meta)

x.get(0)
  // Check: Is x ok or err?
  // ok -> call get(0) on ["hello", "world"] -> "hello"
  // Wrap result -> ok("hello", meta)

x.get(0).uppercase
  // Previous result: ok("hello", meta)
  // Check: Is it ok or err?
  // ok -> call uppercase on "hello" -> "HELLO"
  // Wrap result -> ok("HELLO", meta)
```

**Error propagation:**

If any step in the chain returns an error, subsequent methods are skipped:

```ripple
result := user_data
  .get("users")              // ok([...]) or err("key not found")
  .find(u -> u.id == 5)      // ok(user) or err("not found") or SKIPPED if previous err
  .get("email")              // ok(email) or err or SKIPPED
  .lowercase                 // ok(lowercase_email) or err or SKIPPED
  .send_notification         // ok(()) or err or SKIPPED

// result is either:
// - ok(()) if everything succeeded
// - err(...) from the first operation that failed
```

**The special case:**

There is one special case to be aware of: when working with collections, traits need to “look through” the Result and operate on the inner value, then re-wrap the result (or keep the error if it’s already an error).

```ripple
x := ["this", "that"]
result := ^x.get(0)           // Keep Result wrapped
// result = ok("this", meta)

// Now you can inspect both success and error metadata:
match result ->
  ok(val, meta) -> log "Got " + val + " in " + meta.duration + "ms"
  err(e, meta) -> log "Failed after " + meta.retries + " retries"
```

This transparent Result mapping means you can write clean, fluent chains without manual error checking at every step. Errors automatically propagate, and you handle them once at the end (or let them propagate further up the call chain).

### Pattern Matching

Match is a pure expression that returns whatever its matched arm returns:

```ripple
// Match returns a value
message := match temperature ->
  t < 32 -> "freezing"
  32 <= t < 60 -> "cold"
  60 <= t <= 80 -> "comfortable"
  _ -> "hot"

// Match without assignment still executes (and is traced)
match temperature ->
  t < 32 -> alert "Freezing!"
  t > 100 -> alert "Dangerously hot!"
  _ -> log "Temperature normal"

// Match on Results
match ^database_query ->
  ok(rows, meta) -> 
    log "Retrieved " + rows.length + " rows in " + meta.duration + "ms"
  err(e, meta) -> 
    alert "Query failed: " + e
```

### Bare Expressions for Side Effects

Since everything is traced, you don’t need to capture results unless you’re using them:

```ripple
// Just execute for side effect - automatically traced
log "System starting"
check_health
database_backup
send_notification

// Capture when you need the value
status := check_health
message := "Status: " + status
```

The trace shows everything that happened:

```bash
rvm trace my_script.rip

# [12:34:01] Line 2: log "System starting"
#   -> ok((), {duration: 1.2ms})
# [12:34:01] Line 3: check_health
#   -> ok("healthy", {duration: 234ms})
# [12:34:02] Line 4: database_backup
#   -> err("connection timeout", {duration: 5000ms, retries: 3})
# [12:34:02] Line 5: send_notification
#   -> ok((), {duration: 45ms})
```

### Error Handling Patterns

```ripple
// Pattern 1: Explicit matching
result := ^fetch_data
match result ->
  ok(data) -> process data
  err(e) -> log "Failed: " + e

// Pattern 2: Optional with fallback
config := ?file::read "config.json" or default_config

// Pattern 3: Critical operations
api_key := !file::read "api_key.txt"  // Panic if missing

// Pattern 4: Pipeline with error handling
^fetch_data
  |> match r ->
    ok(data) -> data |> transform |> save
    err(e) -> log "Fetch failed: " + e
```

-----

## Example: Multi-Platform Build

```ripple
targets := [
  {arch: "x86_64", os: "linux"},
  {arch: "aarch64", os: "linux"},
  {arch: "x86_64", os: "darwin"}
]

build := target ->
  !process::run "cargo build --release --target " + target.arch + "-" + target.os
    |> sign
    |> upload_to "releases/"

results := targets
  |> list::parallel_map build, {max_concurrent: 4}

results |> list::partition [failure, success] |> match p ->
  p.failure.length == 0 ->
    io::stdout "✓ All " + p.success.length + " builds succeeded"
    github::create_release "v1.0.0", p.success
    
  p.success.length == 0 ->
    !pagerduty::alert "✗ Build completely failed"
    !sys::exit 1
    
  any ->
    io::stderr "⚠ Partial: " + p.success.length + " ok, " + p.failure.length + " failed"
    slack::alert "Build partially failed. Succeeded: " + p.success
```

-----

## Example: Health Check Monitor

```ripple
!system::schedule "*/5 * * * *"  // Every 5 minutes
!system::trace_to "datadog://api-key"
!process::timeout 30000

check_health := service ->
  match net::get service.url ->
    ok(resp, _) when resp.status == 200 && resp.body.status == "healthy" ->
      ok service.name
    ok(_, _) ->
      err(service.name + " unhealthy")
    err(e, _) ->
      err(service.name + " - " + e)

services := [
  {name: "api", url: "https://api.example.com/health"},
  {name: "worker", url: "https://worker.example.com/health"}
]

results := services.parallel_map check_health, {max_concurrent: 3}

results |> list::partition [failure, success] |> match p ->
  p.failure.length == 0 ->
    metrics::gauge "health.all_up", 1
    
  any ->
    p.failure |> map name ->
      metrics::gauge "health.{name}", 0
      slack::alert "⚠️ " + name + " is unhealthy"
```

-----

## Use Cases

✅ **Perfect for:**

- Build & release automation
- Operational tasks (backups, cleanup, health checks)
- CI/CD pipelines
- Scheduled jobs (replace cron)
- Developer tooling orchestration
- Infrastructure automation

❌ **Not for:**

- Web applications (use Rust, Go, Node)
- Data science (use Python)
- Systems programming (use Rust, C++)
- Mobile apps (use Swift, Kotlin)

Ripple is for the **operational glue code** in your repos.

-----

## Comparison

|Feature        |Bash        |Python            |Airflow       |Ripple          |
|---------------|------------|------------------|--------------|----------------|
|Scheduling     |cron        |APScheduler       |✓ Built-in    |✓ Built-in      |
|Process Mgmt   |systemd     |supervisor        |✓ Built-in    |✓ Built-in      |
|Error Handling |`set -e`    |try/except        |Task retries  |✓ Result type   |
|Observability  |Manual logs |Manual logs       |UI only       |✓ Auto-trace    |
|Partial Success|❌           |Manual tracking   |Task-level    |✓ List.partition|
|Parallelism    |`&` and hope|ThreadPoolExecutor|✓             |✓ Built-in      |
|Type Safety    |❌           |Runtime only      |❌             |✓ Compile-time  |
|Deployment     |Everywhere  |Everywhere        |Cluster needed|Single binary   |

-----

## Installation

⚠️ **Note**: Installation commands below are planned features. Currently, build from source.

```bash
# Planned: Single binary install
curl -fsSL https://ripple-lang.org/install.sh | sh

# Current: Build from source
git clone https://github.com/caige-kelly/interpreter
cd interpreter && zig build -Doptimize=ReleaseFast

# Run tests
zig build test
```

-----

## Quick Start

```ripple
// hello.rip
System.trace_to = "file://./logs/"

io::stdout "Hello, Ripple!"
```

```bash
# Planned usage:
rvm exec hello.rip  # Run once
rvm run hello.rip   # Run as daemon

# Current:
zig build run -- examples/hello.rip
```

-----

## Development Status

### Phase 1: Foundation ✅ Complete

- Lexer, parser, evaluator (56 tests passing, zero memory leaks)
- Arithmetic, strings, comparisons, booleans
- Unary operators, parentheses for grouping
- Boolean operators (`&&`, `||`, `!`) separate from `or`
- No variable shadowing (by design)

### Phase 2: Core Language 🔨 In Progress

- Functions and lambdas (syntax: `x, y -> x + y`)
- Lists and maps
- Pipeline operator (`|>`)
- Pattern matching with guards
- Chained comparisons (`60 <= x <= 80`)

### Phase 3: Error Handling 📋 Designed

- Result type implementation
- `?` (optional), `!` (critical), `^` (keep wrapped) policies
- `or` operator for fallback
- `match` expressions with Result patterns
- Automatic error propagation through pipelines and method chains

### Phase 4: Runtime & Stdlib 📋 Planned

- Process execution, file operations, networking
- Supervisor & tracing system
- `rvm` CLI tool
- Standard library (List, Map, String, Process, Net, etc.)

-----

## Key Implementation Details

### Everything Returns Result

Even literal values are wrapped:

```ripple
5        // ok(5, metadata)
x + y    // ok(result, metadata) or err(...)
```

### Assignment Unwraps

The `:=` operator unwraps Results by default for clean syntax:

```ripple
x := 5 + 3   // x = 8, not ok(8, meta)
```

### Pipeline Policies

`!`, `?`, and `^` are evaluated by the pipeline/assignment context:

```ripple
x := operation       // Unwrapped
x := ^operation      // Wrapped
operation |> next    // Unwrapped
^operation |> match  // Wrapped
```

### No Variable Shadowing

```ripple
x := 10
x := 20  // ERROR: x already defined

// Use pipelines instead:
x := 10 |> increment |> double
```

### IDE Integration

Ripple’s syntax is Python-clean. Type safety comes from IDE tooling:

- Hover to see inferred types
- Inline hints reveal Result types
- Expression traces available in debugger

Best of both worlds: Python’s readability + Rust’s safety + observability built in.

-----

## Documentation

- **Language Reference**: `docs/reference.ripple` - Complete spec
- **Implementation Guide**: `docs/handoff.md` - Technical details and current status

-----

## Development

Ripple is in active development using TDD. Current focus:

- Core language features (functions, collections, pipelines)
- Pattern matching implementation
- Result type and error handling
- Runtime and supervisor design

See `docs/handoff.md` for architecture details and current implementation status.

-----

## License

[To be determined]

-----

## Tagline

**Ripple: Stop duct-taping together bash, Python, cron, and hope.**

Because your ops scripts deserve better than “I think it worked?”
