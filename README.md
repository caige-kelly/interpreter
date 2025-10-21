# Ripple

> ⚠️ **Vision Document**: This README describes Ripple's intended design and architecture. 
> See [`docs/handoff.md`](docs/handoff.md) for current implementation status.
> 
> **Current Status**: Phase 1 complete (lexer, parser, evaluator - 56 tests passing). 
> Phase 2 in progress (functions, collections, pipelines).

**Operational scripts that don't lie about failures**

Stop duct-taping together bash, Python, cron, systemd, and logging just to run reliable automation. Ripple is a functional, pipeline-oriented language designed specifically for operational scripts—with built-in scheduling, supervision, and observability.

## The Problem

Every production system has operational scripts: database backups at 3am, multi-stage build pipelines, release automation, cleanup jobs, health checks. And they're all held together with duct tape:

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

**You need 5 separate tools:**
1. Cron - scheduling
2. Systemd/supervisor - process management
3. Python/bash - the actual logic
4. Logging libraries - observability
5. Monitoring/alerting - know when things break

**And none of them talk to each other.**

## The Ripple Way

```ripple
// backup.rip - everything in one place

// fail if any of the system configurations return Err i.e mis configuration
!system::schedule "0 3 * * *"
!system::trace_to  "s3://logs/ripple/"
!system::on_failure email::configure(email_config_map).send_body("Backups failed")
!process::timeout 600000

                                                                    // Literals - Results, auto-unwrap in safe contexts
databases := ["prod", "staging", "dev"]                             // Result<Ok([...])>
s3_url    := "s3://backups"                                         // Result<Ok("s3://backups")>

!Task.retry backup_db {max_retires: 3}                              // retry backup_db up to 3 times if there is an Err returned, could be top level or next to where it "works"
backup_db := db ->
  !process::run "pg_dump " + db                                      // ! = return value or panic
  |> ?process::run ["gzip", _] or !process::run ["brotli", _]         // try gzip or brotli must work
  |> !S3::upload "{s3_url}/last_night_backups/{db}.zip" _            // s3 must work

results := databases.parallel_map backup_db {max_concurrent: 3}     // return [Result, Result, Result]

results.partition [success, failure] |> match p ->                   // Partition results by ok, err into successes and failures
  p.failure.length == 0 ->
    io::stdout("✓ All " + p.success.length + " databases backed up")
  
  p.success.length == 0 ->
    sys::exit(1)
  
  any ->
    p.failure |> map p -> io::stderr "Failed: " + p
```

```bash
# One command to deploy (planned)
rvm run backup.rip

# Built-in management (planned)
rvm list                 # See all running scripts
rvm logs backup.rip      # View logs  
rvm trace backup.rip     # See execution trace
rvm restart backup.rip   # Graceful restart
```

## What Makes Ripple Different

### 1. Runtime Configuration, Not Just Code

**Other languages:** You write the script, you figure out how to run it  
**Ripple:** Configure the runtime once, it handles execution

```ripple
System.schedule = "0 3 * * *"           // Built-in cron
System.max_memory = "512MB"             // Resource limits
System.trace_to = "jaeger://traces"     // Distributed tracing
System.on_failure = Alert.slack         // Failure hooks

Process.timeout = 600000                // Global timeout
Process.retries = 3                     // Retry failed operations
Process.parallel_limit = 5              // Max concurrency

// Your script - runtime handles the rest
do_work()
```

No more writing timeout wrappers, implementing retry logic, or configuring process supervisors.

### 2. Errors Flow Through Pipelines

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

**Ripple:** Errors flow inline with your logic
```ripple
// Default: Returns Result, handle explicitly
result := ^step1.unwrap_or rollback1                  // unwrap Result, on err execute rollback1 and with ^ propagate error up pipeline
  |> ^step2.unwrap_or rollback2
  |> ^step3.unwrap_or rollback3

match result {
  Ok(v) -> process(v)
  Err(e, meta) -> io::stdout "encountered error: " + e + "...rolled back" then sys::exit(1)
}

// ? = Optional: Errors become none, provide fallback
config := ?file::read("config.json") or default_config

// ! = Critical: Must succeed or crash
critical_config := !file::read("required.json")
```

**Choose your semantics at the call site:**
- (no symbol) = Returns `Result<V, E>`, handle explicitly
- `?` = Optional: Returns `value | none`, use `or` for fallback
- `!` = Critical: Unwraps or crashes, for unrecoverable operations
- `^` = Propagate: Unwrap and return Err up the call chain

### 3. Expression-Level Observability Built In

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
build_artifact("linux")
  |> sign
  |> upload_to("releases/")
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
#System.trace_to = "jaeger://localhost:6831"
#System.trace_to = "datadog://api-key"
#System.trace_to = "file:///var/log/ripple/"
```

### 4. Partial Success Is Explicit

**The killer feature for multi-stage operations.**

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

results := servers.parallel_map(deploy, max_concurrent: 3)

results.partition [failure, success] |> match result ->
  result.failure.length == 0 ->
    io::stdout("✓ Deployed to all " + p.success.length + " servers")
  
  result.success.length == 0 ->
    !PagerDuty::alert("✗ Deploy completely failed")
    !io::exit(1)
  
  any ->
    !Slack::alert("⚠ Partial: " + p.success.length + " ok, " + p.failure.length + " failed")
    rollback p.success  // Rollback what succeeded
```

**How it works:**
- All operations return `Result<T, E>`
- `List.partition` separates successes from failures
- Match with guards checks all three outcomes
- Both lists available for processing/rollback

### 5. Process Management Built In

**Other languages:** Figure out systemd/supervisor/cron yourself

**Ripple:** One CLI for everything (planned)
```bash
rvm run my_script.rip    # Run as daemon with supervision
rvm exec my_script.rip   # One-off execution

# See what's running
rvm list
# NAME              STATUS    LAST RUN              NEXT RUN
# backup.rip        running   2024-10-20 03:00:00   2024-10-21 03:00:00
# deploy.rip        idle      2024-10-19 14:32:15   manual
# cleanup.rip       failed    2024-10-20 01:00:00   2024-10-21 01:00:00

# Debug and manage
rvm logs backup.rip --follow
rvm trace backup.rip --expression 23
rvm restart backup.rip
```

## Language Design

### Core Principles

- **No if/else** - Pattern matching via `match` expressions
- **Explicit error handling** - Everything returns Result by default
- **Immutable** - No variable shadowing, use pipelines
- **Pipelines first** - Data flows through transformations
- **Built-in observability** - Every expression traced automatically

### Quick Tour

**Variables & Functions**
```ripple
x := 42
add := a, b -> a + b
result := add 10 32  // 42
```

**Pipelines**
```ripple
result := "hello world"
  |> string::uppercase
  |> string::split(" ")
  |> map word -> word + "!"
  |> !result::unwrap             // !_.unwrap would probably work? but pretty ugly. 
```

**Pattern Matching** (No `if` keyword!)
```ripple
temperature |> match t ->            // Automatic unwrap by pipeline
  60 <= t <= 80 -> "comfortable"     // Chained comparison
  t < 60 -> "cold"
  t -> "hot"                         // Catch-all

// Result matching
match result ->                      // match pattern to keep Result object in tact
  ok(data, meta) ->
    io::stdout("Success in " + meta.duration + "ms")
  err(msg, meta) ->
    Slack::post("Error: " + msg)
```

**Error Handling**
```ripple
// Returns Result by default
data := match Net::get url ->
  ok(body, _) -> body
  err(e, _) -> panic("Failed: " + e)

// Optional with ?
avatar := ?net::get(avatar_url) or default_avatar

// Critical with !
config := !file::read("critical.json")  // Crashes if missing
```

## Real-World Examples

### Multi-Platform Release Build

```ripple
targets := [
  {arch: "x86_64", os: "linux"},
  {arch: "aarch64", os: "linux"},
  {arch: "x86_64", os: "darwin"}
]

build := target ->
  !process::run("cargo build --release --target " + target.arch + "-" + target.os)
    |> sign
    |> upload_to "releases/"

results := targets 
  |> list::parallel_map build, {max_concurrent: 4}

results |> list::partition [succeeded, failure] |> match p ->
  p.failure.length == 0 ->
    io::stdout("✓ All " + p.success.length + " builds succeeded")
    GitHub::create_release("v1.0.0", p.success)
  
  p.success.length == 0 ->
    !alert::pagerduty("✗ Build completely failed")
    !io::exit(1)
  
  p ->
    IO.stderr("⚠ Partial: " + p.success.length + " ok, " + p.failure.length + " failed")
    Alert.slack("Build partially failed. Succeeded: " + p.success)
```

### Health Check with Retry

```ripple
!System.schedule = "*/5 * * * *"  // Every 5 minutes
!System.trace_to = "datadog://api-key"
!Process.timeout = 30000

check_health := service ->
   match net::get service::url ->
    ok(resp, _) resp.status == 200 && resp.body.status == "healthy" ->
      ok(service.name)
    ok(_, _) ->
      err(service.name + " unhealthy")
    err(e, _) ->
      err(service.name + " - " + e)

services := [
  {name: "api", url: "https://api.example.com/health"},
  {name: "worker", url: "https://worker.example.com/health"}
]

results := services.parallel_map(check_health, max_concurrent: 3)

results |> list::partition [failure, success] |> match p ->
  p.failure.length == 0 ->
    Metrics.gauge("health.all_up", 1)
  
  p ->
    p.failur |> map name ->
      Metrics.gauge "health.{name}" 0
      Alert.slack "⚠️ " + name + " is unhealthy"
```

## Use Ripple For

✅ Build & release automation  
✅ Operational tasks (backups, cleanup, health checks)  
✅ CI/CD pipelines  
✅ Scheduled jobs (replace cron)  
✅ Developer tooling orchestration  
✅ Infrastructure automation  

## Don't Use Ripple For

❌ Web applications (use Rust, Go, Node)  
❌ Data science (use Python)  
❌ Systems programming (use Rust, C++)  
❌ Mobile apps (use Swift, Kotlin)

**Ripple is for the operational glue code in your repos.**

## Comparison

| Feature | Bash | Python | Airflow | Ripple |
|---------|------|--------|---------|--------|
| **Scheduling** | cron | APScheduler | ✓ Built-in | ✓ Built-in |
| **Process Mgmt** | systemd | supervisor | ✓ Built-in | ✓ Built-in |
| **Error Handling** | `set -e` | try/except | Task retries | ✓ Result type |
| **Observability** | Manual logs | Manual logs | UI only | ✓ Auto-trace |
| **Partial Success** | ❌ | Manual tracking | Task-level | ✓ List.partition |
| **Parallelism** | `&` and hope | ThreadPoolExecutor | ✓ | ✓ Built-in |
| **Type Safety** | ❌ | Runtime only | ❌ | ✓ Compile-time |
| **Deployment** | Everywhere | Everywhere | Cluster needed | Single binary |

## Installation

> ⚠️ **Note**: Installation commands below are planned features. Currently, build from source.

```bash
# Planned: Single binary install
curl -fsSL https://ripple-lang.org/install.sh | sh

# Current: Build from source
git clone https://github.com/yourusername/ripple
cd ripple && zig build -Doptimize=ReleaseFast

# Run tests
zig build test
```

## Quick Start

```ripple
// hello.rip
#System.trace_to = "file://./logs/"
IO.stdout("Hello, Ripple!")
```

```bash
# Planned usage:
rvm exec hello.rip     # Run once
rvm run hello.rip      # Run as daemon

# Current:
zig build run -- examples/hello.rip
```

## Current Status

**Phase 1: Foundation** ✅ Complete
- Lexer, parser, evaluator (56 tests passing, zero memory leaks)
- Arithmetic, strings, comparisons, booleans
- Unary operators, parentheses for grouping
- Boolean operators (`&&`, `||`, `!`) separate from `or`
- No variable shadowing (by design)

**Phase 2: Core Language** 🔨 In Progress  
- Functions and lambdas (syntax: `x, y -> x + y`)
- Lists and maps
- Pipeline operator (`|>`)
- Pattern matching with guards
- Chained comparisons (`60 <= x <= 80`)

**Phase 3: Error Handling** 📋 Designed
- Result type implementation
- `?` (optional) and `!` (critical) prefixes
- `or` operator for fallback
- `match` expressions with Result patterns

**Phase 4: Runtime & Stdlib** 📋 Planned
- Process execution, file operations, networking
- Supervisor & tracing system
- `rvm` CLI tool
- Standard library (List, Map, String, Process, Net, etc.)

## Key Design Decisions

### Everything Returns Result
```ripple
// By default, operations return Result<T, E>
body := Net.get(url) |> match ->
  ok(data, _) -> data
  err(e, _) -> handle_error(e)
```

### Prefixes for Intent
```ripple
!operation()  // ! = Must succeed or crash (critical)
?operation()  // ? = May fail, returns value|none (optional)
operation()   // Returns Result, handle explicitly
```

### List.partition for Batch Operations
```ripple
results := items |> List.parallel_map(process)

// Returns {success: [T], failure: [E]}
results |> List.partition |> match p ->
  p p.failure.length == 0 -> "all succeeded"
  p p.success.length == 0 -> "all failed"
  p -> "partial: " + p.success.length + " ok"
```

### No Variable Shadowing
```ripple
x := 10
x := 20  // ERROR: x already defined

// Use pipelines instead:
x := 10 |> increment |> double
```

## Philosophy: Language + IDE Partnership

Ripple's syntax is Python-clean. Type safety and error tracking come from IDE tooling:

- **Hover** to see inferred types
- **Inline hints** reveal Result types
- **Expression traces** available in debugger

**Best of both worlds:** Python's readability + Rust's safety + observability built in.

## Learn More

- **Language Reference**: `docs/reference.ripple` - Complete spec
- **Implementation Guide**: `docs/handoff.md` - Technical details and current status

## Contributing

Ripple is in active development using TDD. Current focus:
- Core language features (functions, collections, pipelines)
- Pattern matching implementation
- Result type and error handling
- Runtime and supervisor design

See `docs/handoff.md` for architecture details and current implementation status.

## License

[To be determined]

---

**Ripple: Stop duct-taping together bash, Python, cron, and hope.**

*Because your ops scripts deserve better than "I think it worked?"*
