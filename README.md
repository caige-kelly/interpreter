
# Ripple

⚙️ **Operational scripts that don’t lie about failures.**

Ripple is a **functional, pipeline-oriented language** for reliable automation.  
It replaces the fragile glue of Bash, Python, cron, and systemd with a single, observable runtime.  

Stop duct-taping together five tools just to run a backup at 3 AM.  
Ripple unifies scheduling, supervision, and tracing — so your scripts tell the truth about what succeeded, what failed, and why.

> Because your ops scripts deserve better than *“I think it worked?”*

---

## The Problem

Every production system runs a menagerie of operational scripts — backups, deploys, health checks, build jobs — scattered across cron, bash, and Python.

```bash
#!/bin/bash
set -e  # Pray nothing fails silently

# /etc/cron.d/backup
0 3 * * * /opt/scripts/backup.sh >> /var/log/backup.log 2>&1
```

```python
import subprocess, logging

def backup():
    try:
        subprocess.run(["pg_dump", "prod"], check=True)
        # Upload to S3...
    except subprocess.CalledProcessError as e:
        logging.error(f"Backup failed: {e}")
```

You end up juggling:

- **cron** for scheduling  
- **systemd** or **supervisor** for process management  
- **Python/bash** for the logic  
- **logging libraries** for observability  
- **alerting systems** for failures  

And none of them share state, logs, or guarantees.

---

## The Ripple Way

Ripple scripts describe **what** should happen *and* **how** it runs — in one file.

```ripple
// backup.rip
process::doc::header """  
  Nightly backups run at 3:00 AM.  
  Logs stream to s3://logs/ripple/.  
  Ops is alerted on failure.  
"""

!system::schedule "0 3 * * *"
!system::trace_to "s3://logs/ripple/"
!system::on_failure email::configure(?email_config).send_body("Backups failed")
!process::timeout 600000

databases := ["prod", "staging", "dev"]
s3_url := "s3://backups"

backup_db := db ->
  process::run ["pg_dump", db]
    |> dump ->
      process::run ["gzip", dump, ">", "backup.gz"]
      or process::run ["brotli", dump, ">", "backup.br"]
    |> s3::upload "{s3_url}/{db}.zip" _

results := ^databases.parallel_map backup_db, {max_concurrent: 3}

results |> list::partition [failure, success] |> match p ->
  p.failure.length == 0 ->
    io::stdout "✓ " + p.success.length + " databases backed up"
  any ->
    p.failure |> map f -> io::stderr "Failed: " + f
```

```bash
rvm run backup.rip      # Supervised runtime
rvm logs backup.rip     # View logs
rvm trace backup.rip    # Inspect execution trace
```

Ripple scripts are declarative and self-contained: logic, retries, scheduling, tracing, and failure policies — all expressed together.

---

## Why Ripple?

| Feature | Bash | Python | Airflow | **Ripple** |
|----------|-------|---------|-----------|------------|
| Scheduling | cron | APScheduler | ✓ Built-in | ✓ Built-in |
| Process Mgmt | systemd | supervisor | ✓ Built-in | ✓ Built-in |
| Error Handling | `set -e` | try/except | Task retries | ✓ Result type |
| Observability | manual | manual | UI only | ✓ Auto-trace |
| Partial Success | ❌ | manual | task-level | ✓ First-class |
| Parallelism | `&` and hope | ThreadPoolExecutor | ✓ | ✓ Built-in |
| Type Safety | ❌ | runtime | ❌ | ✓ compile-time |
| Deployment | everywhere | everywhere | cluster | single binary |

Ripple’s job is to make *operational reliability* a language feature — not an afterthought.

---

## Core Design Principles

- **Functional, not procedural.** Every expression returns a `Result<T, E>`.  
- **No `if/else`.** Use `match` expressions and guards.  
- **Immutable by default.** Values don’t change; pipelines transform.  
- **Pipelines first.** Data flows left-to-right.  
- **Built-in observability.** Every expression is traced automatically.  

---

## The Ripple Flow Model

Everything that happens in Ripple is a *Result* — success or failure — wrapped with metadata.  
Literals, expressions, function calls: all return `ok(value, meta)` or `err(error, meta)`.

```ripple
5                // ok(5, metadata)
"hello"          // ok("hello", metadata)
divide 10, 0     // err("division by zero", metadata)
```

This means errors aren’t exceptional; they’re values that flow inline with logic.  
You can see, inspect, or transform them just like any other value.

---

### Assignment Unwraps by Default

Assignments (`:=`) automatically unwrap successful Results for ergonomic syntax.

```ripple
x := 5          // x = 5
y := x + 3      // y = 8
name := "Alice" // name = "Alice"
```

You don’t have to unwrap manually unless you want the full `Result` object.

---

### The `^`, `!`, and `?` Policies

Evaluator policies control how Results behave during assignment or in pipelines:

```ripple
x := operation          // default: unwrap
x := ^operation         // keep wrapped
x := !operation         // unwrap or panic
x := ?operation or def  // unwrap or use default
```

Only one policy can apply at once — `?!` and `^?` are compile errors.

These same rules apply in pipelines:

```ripple
^fetch_data
  |> match r ->
    ok(data) -> transform data
    err(e) -> log "Fetch failed: " + e
```

---

### Pipelines

Ripple’s pipeline operator `|>` passes Results automatically through each stage.

```ripple
result := "hello world"
  |> string::uppercase
  |> string::split " "
  |> map word -> word + "!"
  |> list::join ", "
```

If any step fails, the pipeline short-circuits — no manual checks, no swallowed errors.

---

### Method Chaining Through Results

Methods automatically act on the *inner* value of a Result.

```ripple
x := ["hello", "world"]
value := x.get(0).uppercase
// ok("HELLO")

y := []
value := y.get(0).uppercase
// err("index out of bounds")
```

Ripple transparently unwraps for each method call and re-wraps the outcome.  
Errors propagate; later methods are skipped automatically.

---

### Pattern Matching

`match` is Ripple’s only conditional. It’s an expression that returns a value.

```ripple
message := match temperature ->
  t < 32 -> "freezing"
  32 <= t < 60 -> "cold"
  60 <= t <= 80 -> "comfortable"
  _ -> "hot"
```

Matching on `Result` types is just as direct:

```ripple
match ^database_query ->
  ok(rows, meta) ->
    log "Retrieved " + rows.length + " rows in " + meta.duration + "ms"
  err(e, meta) ->
    alert "Query failed: " + e
```

---

### Bare Expressions for Side Effects

Any expression can stand alone. It’s traced automatically even if you ignore its value.

```ripple
log "System starting"
check_health
database_backup
send_notification
```

Traces tell the story:

```bash
rvm trace my_script.rip
# [12:34:01] log "System starting" -> ok((), {1.2ms})
# [12:34:02] check_health -> ok("healthy", {234ms})
# [12:34:03] database_backup -> err("timeout", {5s, retries: 3})
```

---

### Error Handling Patterns

Ripple offers expressive ways to handle failure inline:

```ripple
// 1. Explicit matching
result := ^fetch_data
match result ->
  ok(data) -> process data
  err(e) -> log "Failed: " + e

// 2. Optional with fallback
config := ?file::read "config.json" or default_config

// 3. Critical operations
api_key := !file::read "api_key.txt"

// 4. Pipeline guard
^fetch_data |> match r ->
  ok(data) -> transform data
  err(e) -> log "Fetch failed: " + e
```

---

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

results := targets.parallel_map build, {max_concurrent: 4}

results |> list::partition [failure, success] |> match p ->
  p.failure.length == 0 ->
    io::stdout "✓ " + p.success.length + " builds succeeded"
    github::create_release "v1.0.0", p.success
  any ->
    io::stderr "⚠ Partial success"
    slack::alert "Build partially failed: " + p.failure.length + " targets"
```

---

## Example: Health Check Monitor

```ripple
!system::schedule "*/5 * * * *"    // Every 5 minutes
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
      slack::alert "⚠ " + name + " is unhealthy"
```

---

## Use Cases

✅ Perfect for:  
- Build & release automation  
- Backups, cleanup, health checks  
- CI/CD pipelines  
- Scheduled jobs (cron replacement)  
- Infrastructure orchestration  

❌ Not for:  
- Web apps  
- Data science  
- Systems programming  
- Mobile development  

Ripple is for **operational glue** — the scripts that keep everything running.

---

## Development Status

**Phase 1: Foundation ✅ Complete**  
Lexer, parser, evaluator (56 tests passing, zero leaks)

**Phase 2: Core Language 🚧 In progress**  
Functions, lists/maps, pipelines, pattern matching

**Phase 3: Error Handling 📋 Designed**  
Result type, policies (`? ! ^`), `or`, `match`

**Phase 4: Runtime & Stdlib 📋 Planned**  
Process, file, network, supervisor, tracing, `rvm` CLI

---

## Installation

```bash
# Planned
curl -fsSL https://ripple-lang.org/install.sh | sh

# Current
git clone https://github.com/caige-kelly/interpreter
cd interpreter && zig build -Doptimize=ReleaseFast
zig build test
```

---

## Quick Start

```ripple
// hello.rip
!system::trace_to "file://./logs/"
io::stdout "Hello, Ripple!"
```

```bash
# Planned
rvm exec hello.rip
# Current
zig build run -- examples/hello.rip
```

---

## License

MIT

---

### Tagline

**Ripple:** *Stop duct-taping together bash, Python, cron, and hope.*
