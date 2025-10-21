# Ripple

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

```
// backup.rip - everything in one place
#System.schedule = "0 3 * * *"
#System.trace_to = "s3://logs/ripple/"
#System.on_failure = @Alert.pagerduty "Backup failed"
#Process.timeout = 600000
#Process.retries = 3

databases := ["prod", "staging", "dev"]

backup_db := db ->
  @Process.run ("pg_dump " + db + " > " + db + ".sql")
    then @Process.run ("gzip " + db + ".sql")
    then @S3.upload (db + ".sql.gz") "backups/"

results := databases 
  |> List.parallel_map backup_db {max_concurrent: 3}

results |> List.partition_results |> match ->
  all_ok(backups, meta) ->
    @Log.info ("Backed up in " + meta.duration + "ms")
  partial(ok, failed, meta) ->
    @Alert.send ("Failed: " + #String.join (failed |> List.map .db) ", ")
    // Automatic rollback for what succeeded
```

```bash
# One command to deploy
rvm run backup.rip

# Built-in management
rvm list                 # See all running scripts
rvm logs backup.rip      # View logs  
rvm trace backup.rip     # See execution trace
rvm restart backup.rip   # Graceful restart
```

## What Makes Ripple Different

### 1. Runtime Configuration, Not Just Code

**Other languages:** You write the script, you figure out how to run it  
**Ripple:** Configure the runtime once, it handles execution

```
#System.schedule = "0 3 * * *"           // Built-in cron
#System.max_memory = "512MB"             // Resource limits
#System.trace_to = "jaeger://traces"     // Distributed tracing
#System.on_failure = @Alert.slack        // Failure hooks

#Process.timeout = 600000                // Global timeout
#Process.retries = 3                     // Retry failed operations
#Process.parallel_limit = 5              // Max concurrency

// Your script - runtime handles the rest
do_work
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
```
// Monadic (@): Explicit error handling
result := @step1
  |> @step2 _
  |>  @step3 _
  |> match ->
       ok(v, _) -> v
       err(msg, meta) ->
         @Log.error ("Failed at " + meta.stage + ": " + msg) then #Result.ok rollback_mech

// Tolerant (#): Errors become none, provide fallback
config := #File.read "config.json" 
  or default_config
```

**Choose your semantics at the call site:**
- `@` = Monadic: Returns `Result<V, E>`, must handle explicitly
- `#` = Tolerant: Errors collapse to `none`, chain with `or`

### 3. Expression-Level Observability Built In

**Python:** Add logging manually everywhere
```python
logger.info("Starting step 1")
result1 = step1()
logger.info(f"Step 1 done in {duration}ms")
# ... repeat forever
```

**Ripple:** Every expression is automatically traced
```
// Just write your logic
@build_artifact "linux"
  then (artifact -> @sign artifact)
  then (signed -> @upload signed "releases/")
```

```bash
# Automatic traces for every expression
rvm trace build.rip

# Output:
# [12:34:01.234] Line 5: build_artifact "linux" 
#   -> ok("app-v1.0-linux", {duration: 2341ms, memory: 234MB})
# [12:34:03.575] Line 6: sign 
#   -> ok("app-v1.0-linux.sig", {duration: 89ms})
# [12:34:03.664] Line 7: upload
#   -> err("network timeout", {duration: 1205ms, retries: 3})
```

Export traces anywhere:
```
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

**Ripple:** Built into the type system
```
servers := ["web-1", "web-2", "web-3"]

results := servers 
  |> List.parallel_map (s -> @deploy s)

results |> List.partition_results |> match -> // automatic iteration with match
  ok(deploys, meta) ->
    @IO.stdout ("✓ Deployed: " + #String.join (deploys|> List.map .server) ", ")
  err(failed, meta) ->
    @IO.stderr ("✗ Failed: " + #String.join (failed |> List.map .server) ", ")
    @rollback succeeded  // Rollback what succeeded
```

### 5. Process Management Built In

**Other languages:** Figure out systemd/supervisor/cron yourself

**Ripple:** One CLI for everything
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
- **Explicit error handling** - Choose monadic (`@`) or tolerant (`#`) semantics at call site
- **Immutable** - No variable rebinding, use pipelines
- **Pipelines first** - Data flows through transformations
- **Built-in observability** - Every expression traced automatically

### Quick Tour

**Variables & Functions**
```
x := 42
add := a, b -> a + b
result := add 10 32  // 42
```

**Pipelines**
```
result := "hello world"
  |> #String.uppercase _
  |> #String.split " "
  |> #List.map (word -> word + "!")
```

**Pattern Matching**
```
response |> match ->
  ok(data, meta) ->
    @IO.stdout ("Success in " + meta.duration + "ms")
  err(msg, meta) ->
    @Slack.post ("Error: " + msg)
```

**Side Effects with `tap`**
```
result := @Net.post url payload
  |> tap err(msg, _) -> @Slack.post ("Failed: " + msg)
  |> @Map.parse _
  |> #Result.unwrap_or_none
  or default_response
```

## Real-World Examples

### Multi-Platform Release Build

```
targets := [
  {arch: "x86_64", os: "linux"},
  {arch: "aarch64", os: "linux"},
  {arch: "x86_64", os: "darwin"}
]

build := target ->
  @Process.run ("cargo build --release --target " + target.arch + "-" + target.os)
  then @Process.run ("./scripts/sign.sh " + target.arch + "-" + target.os)
  then @S3.upload ("target/" + target.arch + "-" + target.os + "/release/app") "releases/"
  then target.arch + "-" + target.os

results := targets 
  |> List.parallel_map (t -> build t) {max_concurrent: 4}

results |> List.partition_results |> match ->
  ok(_, meta) len(builds) == len(targets) ->
    @IO.stdout ("✓ All builds succeeded in " + meta.duration + "ms")
    @GitHub.create_release "v1.0.0" builds
  ok(succeeded) len(succeeded) < len(targets) ->
    @IO.stdout ("✓ Built: " + #String.join succeeded ", ")
    @Slack.post ("Release partially failed. Built: " + succeeded)
```

### Health Check with Retry

```
#System.schedule = "*/5 * * * *"  // Every 5 minutes
#System.trace_to = "datadog://api-key"
#Process.timeout = 30000

check_health := service ->
  @Net.get service.url {timeout: 5000}
  then resp -> 
    @Result.ensure r -> r.status == 200 && r.body.status == "healthy"
    then service.name
    or service.name + " unhealthy"
    

services := [
  {name: "api", url: "https://api.example.com/health"},
  {name: "worker", url: "https://worker.example.com/health"}
]

results := services
  |> List.parallel_map (s -> check_health s) {max_concurrent: 3}

results |> List.partition_results |> match ->
  ok() -> @Metrics.gauge "health.all_up" 1
  error(unhealthy) ->
    unhealthy |> List.each (f ->
      @Metrics.gauge ("health." + f.value.name) 0
      @Alert.slack ("⚠️ " + f.value.name + " is unhealthy")
    )
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
| **Error Handling** | `set -e` | try/except | Task retries | ✓ Type system |
| **Observability** | Manual logs | Manual logs | UI only | ✓ Auto-trace |
| **Partial Success** | ❌ | Manual tracking | Task-level | ✓ Built-in |
| **Parallelism** | `&` and hope | ThreadPoolExecutor | ✓ | ✓ Built-in |
| **Type Safety** | ❌ | Runtime only | ❌ | ✓ Compile-time |
| **Deployment** | Everywhere | Everywhere | Cluster needed | Single binary |

## Installation

```bash
# Single binary install
curl -fsSL https://ripple-lang.org/install.sh | sh

# Or build from source
git clone https://github.com/yourusername/ripple
cd ripple && zig build -Doptimize=ReleaseFast

# Verify
rvm --version
```

## Quick Start

```
// hello.rip
#System.trace_to = "file://./logs/"
@IO.stdout "Hello, Ripple!"
```

```bash
rvm exec hello.rip     # Run once
rvm run hello.rip      # Run as daemon
rvm trace hello.rip    # View trace
```

## Current Status

**Phase 1: Foundation** ✅ Complete
- Lexer, parser, evaluator (56 tests passing)
- Arithmetic, strings, comparisons working

**Phase 2: Core Language** 🔨 In Progress  
- Functions and lambdas
- Lists and maps
- Pipeline operator  
- Pattern matching

**Phase 3: Error Handling** ⏳ Designed
- Result type implementation
- `@` vs `#` semantics
- `or`, `then`, `tap` operators

**Phase 4: Runtime & Stdlib** 📋 Next
- Process execution, file operations, networking
- Supervisor & tracing system

## Philosophy: Language + IDE Partnership

Ripple's syntax is Python-clean. Type safety and error tracking come from IDE tooling:

- **Hover** to see inferred types
- **IDE marks** `@` functions (must handle) vs `#` functions (tolerant)
- **Inline hints** reveal error paths
- **Expression traces** available in debugger

**Best of both worlds:** Python's readability + Haskell's safety + observability built in.

## Learn More

- **Language Reference**: `docs/reference.ripple` - Complete spec
- **Implementation Guide**: `docs/handoff.md` - Technical details

## Contributing

Ripple is in active development using TDD. Current focus:
- Core language features (functions, collections, pipelines)
- Pattern matching implementation
- Runtime and supervisor design

See `docs/handoff.md` for architecture details.

## License

[To be determined]

---

**Ripple: Stop duct-taping together bash, Python, cron, and hope.**
