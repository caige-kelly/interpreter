# Ripple

**Operational scripts that don't lie about failures**

Stop duct-taping together bash, Python, cron, systemd, and logging just to run a reliable automation script.

## The Problem

Every production system has operational scripts:
- Database backups that run at 3am
- Multi-stage build pipelines  
- Release automation across environments
- Cleanup jobs, health checks, data syncs

And they're all held together with:

```bash
#!/bin/bash
set -e  # Pray nothing fails silently

# /etc/cron.d/backup
0 3 * * * /opt/scripts/backup.sh >> /var/log/backup.log 2>&1
```

```python
# backup.py - scattered across 5 different systems
import subprocess, logging, boto3, sys
from apscheduler.schedulers.blocking import BlockingScheduler

logging.basicConfig(filename='/var/log/backup.log')
scheduler = BlockingScheduler()

@scheduler.scheduled_job('cron', hour=3)
def backup():
    databases = ['prod', 'staging', 'dev']
    failed = []
    
    for db in databases:
        try:
            subprocess.run(['pg_dump', db], check=True)
            subprocess.run(['gzip', f'{db}.sql'], check=True)
            # Upload to S3...
        except subprocess.CalledProcessError as e:
            failed.append(db)
            logging.error(f'{db} failed: {e}')
    
    if failed:
        # How do you know what succeeded?
        # How do you rollback partial failures?
        # How do you trace where it broke?
        send_alert(f"Backup failed: {failed}")

if __name__ == '__main__':
    scheduler.start()
```

**You need 5 separate tools:**
1. **Cron** - scheduling
2. **Systemd/supervisor** - process management
3. **Python/bash** - the actual logic
4. **Logging libraries** - observability
5. **Monitoring/alerting** - know when things break

And **none of them talk to each other.**

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
    |> @Result.and_then _ -> @Process.run ("gzip " + db + ".sql")
    |> @Result.and_then _ -> @S3.upload (db + ".sql.gz") "backups/"

results := databases 
  |> @List.parallel_map backup_db {max_concurrent: 3}

results |> @List.partition_results |> match ->
  all_ok(backups, meta) ->
    @Log.info ("Backed up " + #String.join backups ", " + " in " + meta.duration + "ms")
  partial(succeeded, failed, meta) ->
    @Log.info ("Succeeded: " + #String.join succeeded ", ")
    @Alert.send ("Failed: " + #String.join (failed |> @List.map .db) ", ")
    // meta.traces shows exactly where each failure happened
```

```bash
# One command to deploy
rvm run backup.rip

# Built-in management
rvm list                 # See all running scripts
rvm logs backup.rip      # View logs  
rvm trace backup.rip     # See execution trace of every expression
rvm restart backup.rip   # Graceful restart
rvm stop backup.rip      # Stop
```

## What Makes Ripple Different

### 1. Configurable Runtime - Not Just a Language

**Bash/Python:** You write the script, you figure out how to run it  
**Ripple:** Configure the runtime, it handles execution

```
// Configure once at the top
#System.schedule = "0 3 * * *"           // Built-in cron
#System.max_memory = "512MB"             // Resource limits
#System.trace_to = "jaeger://traces"     // Distributed tracing
#System.on_failure = @Alert.slack        // Failure hooks

#Process.timeout = 600000                // 10 minute timeout
#Process.retries = 3                     // Retry failed operations
#Process.retry_backoff = "exponential"   // Smart backoff
#Process.parallel_limit = 5              // Max concurrency

// Your script - runtime does the rest
@do_work
```

**No more:**
- Writing timeout wrappers
- Implementing retry logic
- Setting up logging infrastructure
- Configuring process supervisors
- Writing cron syntax

### 2. Errors Are First-Class - Not Exceptions

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

**Ripple:** Errors flow through your pipeline
```
@step1
  |> @Result.and_then step2
  |> @Result.and_then step3
  |> match ->
       ok(result, meta) -> result
       err(msg, meta) ->
         // meta tells you exactly which step failed
         @rollback meta.completed_steps
```

**Caller chooses error semantics:**
```
// @ = Explicit: must handle errors
config := @File.read "config.json"
config |> match ->
  ok(data, _) -> data
  err(msg, _) -> @IO.exit 1

// # = Tolerant: errors become none, provide fallback
config := #File.read "config.json" or default_config
```

### 3. Expression-Level Observability - Built In

**Python:** Add logging manually everywhere
```python
logger.info("Starting step 1")
result1 = step1()
logger.info(f"Step 1 done in {duration}ms")
logger.info("Starting step 2")
# ... ad infinitum
```

**Ripple:** Every expression is automatically traced
```
// Just write your logic
@build_artifact "linux"
  |> @Result.and_then (artifact -> @sign artifact)
  |> @Result.and_then (signed -> @upload signed "releases/")
```

```bash
# Automatic traces for every expression
rvm trace build.rip

# Output:
# [12:34:01.234] Line 5: @build_artifact "linux" 
#   -> ok("app-v1.0-linux", {duration: 2341ms, memory: 234MB})
# [12:34:03.575] Line 6: @sign 
#   -> ok("app-v1.0-linux.sig", {duration: 89ms})
# [12:34:03.664] Line 7: @upload
#   -> err("network timeout", {duration: 1205ms, retries: 3})
```

Export traces anywhere:
```
#System.trace_to = "jaeger://localhost:6831"
#System.trace_to = "s3://logs/traces/"
#System.trace_to = "file:///var/log/ripple/"
#System.trace_to = "datadog://api-key"
```

### 4. Process Management - Built In

**Bash/Python:** Figure out systemd/supervisor/cron yourself

**Ripple:** One CLI for everything
```bash
# Run as daemon with supervision
rvm run my_script.rip

# One-off execution
rvm exec my_script.rip

# See what's running
rvm list
# Output:
# NAME              STATUS    LAST RUN              NEXT RUN
# backup.rip        running   2024-10-20 03:00:00   2024-10-21 03:00:00
# deploy.rip        idle      2024-10-19 14:32:15   manual
# cleanup.rip       failed    2024-10-20 01:00:00   2024-10-21 01:00:00

# View logs
rvm logs backup.rip
rvm logs backup.rip --follow

# Debug failures
rvm trace backup.rip
rvm trace backup.rip --expression 23  # See exact failure point

# Management
rvm restart backup.rip
rvm stop backup.rip
rvm kill backup.rip
```

### 5. Partial Success Is Explicit

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

# Now manually handle partial success
if failed:
    print(f"Deployed to: {succeeded}")
    print(f"Failed: {failed}")
    # Rollback? Which servers? How?
```

**Ripple:** Built into the type system
```
servers := ["web-1", "web-2", "web-3"]

results := servers 
  |> @List.map (s -> @deploy s)

results |> @List.partition_results |> match ->
  all_ok(deploys, meta) ->
    @IO.stdout "✓ Deployed to all servers"
  partial(succeeded, failed, meta) ->
    @IO.stdout ("✓ Deployed: " + #String.join succeeded ", ")
    @IO.stderr ("✗ Failed: " + #String.join (failed |> @List.map .server) ", ")
    @rollback succeeded  // Rollback what succeeded
```

### 6. Pipelines - Not Procedures

**Bash:** Everything is mutations and subshells
```bash
result=$(step1)
result=$(echo "$result" | step2)
result=$(echo "$result" | step3)
```

**Python:** Imperative with lots of variables
```python
result = step1()
result = step2(result)
result = step3(result)
```

**Ripple:** Data flows through transformations
```
result :=
  @step1
    |> @step2 _
    |> @step3 _
    |> match ->
         ok(val, _) -> val
         err(msg, meta) ->
           @Log.error ("Failed at " + meta.stage + ": " + msg)
           @IO.exit 1
```

## Real-World Examples

### Multi-Platform Release Build

```
targets := [
  {arch: "x86_64", os: "linux"},
  {arch: "aarch64", os: "linux"},
  {arch: "x86_64", os: "windows"},
  {arch: "x86_64", os: "darwin"}
]

build := target ->
  @Process.run ("cargo build --release --target " + target.arch + "-" + target.os)
    |> @Result.and_then _ -> @Process.run ("./scripts/sign.sh " + target.arch + "-" + target.os)
    |> @Result.and_then _ -> @S3.upload ("target/" + target.arch + "-" + target.os + "/release/app") "releases/"
    |> @Result.map _ -> target.arch + "-" + target.os

// Build all targets in parallel
results := targets 
  |> @List.parallel_map (t -> build t) {max_concurrent: 4}

// Handle partial success explicitly
results |> @List.partition_results |> match ->
  all_ok(builds, meta) ->
    @IO.stdout ("✓ All builds succeeded in " + meta.duration + "ms")
    @GitHub.create_release "v1.0.0" builds
  partial(succeeded, failed, meta) ->
    @IO.stdout ("✓ Built: " + #String.join succeeded ", ")
    @IO.stderr ("✗ Failed: " + #String.join (failed |> @List.map .target) ", ")
    @Slack.post ("Release partially failed. Built: " + succeeded)
```

### Database Backup with Cleanup

```
#System.schedule = "0 3 * * *"
#System.trace_to = "s3://logs/backup-traces/"
#System.on_failure = @Alert.pagerduty
#Process.timeout = 1800000  // 30 minutes

databases := ["users", "orders", "analytics"]

backup_and_cleanup := db ->
  timestamp := @Time.now |> @Time.format "YYYYMMDD-HHmmss"
  filename := db + "-" + timestamp + ".sql.gz"
  
  @Process.run ("pg_dump " + db + " | gzip > /tmp/" + filename)
    |> @Result.and_then _ -> @S3.upload ("/tmp/" + filename) ("backups/" + db + "/")
    |> @Result.and_then _ -> @File.delete ("/tmp/" + filename)
    |> @Result.and_then _ -> @S3.delete_old ("backups/" + db) {keep_last: 30}
    |> @Result.map _ -> {db: db, file: filename}

results := databases
  |> @List.parallel_map backup_and_cleanup {max_concurrent: 2}

results |> @List.partition_results |> match ->
  all_ok(backups, meta) ->
    @Log.info ("Backed up " + #List.length backups + " databases")
    @Metrics.gauge "backup.success" (#List.length backups)
  partial(ok, failed, meta) ->
    ok |> @List.each (b -> @Log.info ("✓ " + b.db))
    failed |> @List.each (f -> 
      @Log.error ("✗ " + f.value.db + ": " + f.error)
      @Metrics.increment "backup.failure"
    )
```

### Health Check with Circuit Breaker

```
#System.schedule = "*/5 * * * *"  // Every 5 minutes
#System.trace_to = "datadog://api-key"
#Process.timeout = 30000

services := [
  {name: "api", url: "https://api.example.com/health"},
  {name: "worker", url: "https://worker.example.com/health"},
  {name: "db", url: "https://db.example.com/health"}
]

check_health := service ->
  @Net.get service.url {timeout: 5000}
    |> @Result.and_then (resp -> 
         @Result.ensure resp 
           (r -> r.status == 200 && r.body.status == "healthy")
           (service.name + " unhealthy")
       )
    |> @Result.map _ -> service.name

results := services
  |> @List.parallel_map (s -> check_health s) {max_concurrent: 3}

results |> @List.partition_results |> match ->
  all_ok(_, _) ->
    @Metrics.gauge "health.all_up" 1
  partial(healthy, unhealthy, _) ->
    healthy |> @List.each (s -> @Metrics.gauge ("health." + s) 1)
    unhealthy |> @List.each (f ->
      @Metrics.gauge ("health." + f.value.name) 0
      @Alert.slack ("⚠️ " + f.value.name + " is unhealthy: " + f.error)
    )
```

### CI/CD Pipeline

```
// ci.rip - explicit error paths at every stage
#Process.timeout = 1800000
#System.trace_to = "file:///var/log/ripple/ci/"

@Git.fetch
  |> @Result.and_then _ -> @Process.run "cargo test --all"
  |> tap err(msg, meta) ->
       @GitHub.comment "Tests failed: " + msg
       @Metrics.increment "ci.test.failure"
  |> @Result.and_then _ -> @Process.run "cargo build --release"
  |> tap err(msg, meta) ->
       @GitHub.comment "Build failed: " + msg
       @Metrics.increment "ci.build.failure"
  |> @Result.and_then _ -> @Docker.build {tag: "myapp:latest"}
  |> @Result.and_then img -> @Docker.push img
  |> @Result.and_then _ -> @K8s.apply "deployment.yaml"
  |> match ->
       ok(_, meta) ->
         @GitHub.comment "✓ Deployed successfully"
         @Slack.post "#deploys" "Deployed to production"
         @Metrics.increment "ci.deploy.success"
       err(msg, meta) ->
         @GitHub.comment ("✗ Deploy failed at: " + meta.stage)
         @Slack.post "#incidents" ("Deploy failed: " + msg)
         @rollback meta.completed_stages
```

## Use Ripple For

✅ **Build & release automation** - Multi-stage, multi-platform, with rollback  
✅ **Operational tasks** - Backups, cleanup, health checks, data syncs  
✅ **CI/CD pipelines** - Explicit error paths, automatic retries  
✅ **Scheduled jobs** - Replace cron with built-in scheduling  
✅ **Developer tooling** - Code generation, linting, formatting orchestration  
✅ **Infrastructure automation** - Provisioning, deployment, monitoring

## Don't Use Ripple For

❌ Web applications (use Rust, Go, Node)  
❌ Data science (use Python)  
❌ Systems programming (use Rust, C++)  
❌ Mobile apps (use Swift, Kotlin)

**Ripple is for the operational glue code in your repos - the stuff that's currently bash or Python scripts.**

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
| **Learning Curve** | Low | Low | High | Medium |
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
# Run once
rvm exec hello.rip

# Run as daemon
rvm run hello.rip

# View trace
rvm trace hello.rip
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
- Process execution (`@Process.run`)
- File operations (`@File.*`)
- Network (`@Net.*`)
- Supervisor & tracing

## Philosophy

**Ripple syntax is Python-clean.** Type safety and error tracking come from IDE tooling:

- Hover to see inferred types  
- IDE marks `@` functions (can fail) differently from `#` (tolerant)
- Inline hints reveal error paths
- Expression traces available in debugger

**Best of both worlds:** Python's readability + Haskell's safety + observability built in.

## Language Principles

**No if/else** - Pattern matching via `match` expressions  
**Explicit errors** - Choose `@` (must handle) or `#` (graceful fallback)  
**Immutable** - No variable rebinding, use pipelines  
**Pipelines first** - Data flows through transformations  
**Built-in observability** - Every expression traced automatically

## Learn More

- **Language Reference**: `docs/reference.ripple` - Complete spec
- **Implementation Guide**: `docs/handoff.md` - Technical details  
- **Community**: [Discord/Forum TBD]

## Contributing

Ripple is in active development using TDD. Current focus:
- Core language features (functions, collections, pipelines)
- Pattern matching implementation
- Runtime and supervisor design

See `docs/handoff.md` for architecture and contribution guidelines.

## License

[To be determined]

---

**Ripple: Stop duct-taping together bash, Python, cron, and hope.**

Write operational scripts with built-in scheduling, supervision, and observability.
