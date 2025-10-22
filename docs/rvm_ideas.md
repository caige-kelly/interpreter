# RVM Ideas & Design Considerations

## Documentation as Data

`process::doc::*` becomes **executable documentation** — not comments that drift out of sync, but structured metadata that's queryable and enforceable.

```ripple
process::doc::header """
  Nightly database backups with S3 replication.
  Critical: must complete before 6 AM when analytics jobs start.
"""

process::doc::author "ops-team@company.com"
process::doc::oncall "pagerduty://schedule/db-backups"
process::doc::runbook "https://wiki.company.com/runbooks/backup"

process::doc::invariant "All databases must backup or alert"
process::doc::dependency "PostgreSQL 14+, AWS CLI, S3 bucket write access"

!system::schedule "0 3 * * *"
!system::timeout 10800000  // 3 hours
!system::trace "error-only"

// ... actual logic
```

Then `rvm explain` becomes:

```bash
$ rvm explain backup.rip

backup.rip
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Nightly database backups with S3 replication.
Critical: must complete before 6 AM when analytics jobs start.

Author:       ops-team@company.com
On-call:      pagerduty://schedule/db-backups
Runbook:      https://wiki.company.com/runbooks/backup

Schedule:     Daily at 03:00 UTC (0 3 * * *)
Timeout:      3 hours
Trace level:  error-only

Invariants:
  • All databases must backup or alert

Dependencies:
  • PostgreSQL 14+
  • AWS CLI
  • S3 bucket write access

Last execution: 2025-10-22 03:00 ✓ (4m 23s)
```

---

## Trace Level Semantics

```ripple
!system::trace "silent"      // No trace output (still logged to backend)
!system::trace "error-only"  // Only failures and errors
!system::trace "terse"       // One line per top-level expression
!system::trace "verbose"     // Every expression (default)
!system::trace "debug"       // Includes variable bindings, memory usage

// Or target-specific
!system::trace_to "stdout://terse"
!system::trace_to "datadog://verbose"
!system::trace_to "file:///var/log/ripple/debug"
```

This solves the noise problem: dev/debug uses verbose, production uses error-only unless you need to diagnose.

### Trace Format Design

Since everything's traced, the format matters:

```
[timestamp] [duration] [memory] expression -> result

[03:00:00.123] [234ms] [2.1MB] fetch_data -> ok(1247 rows)
[03:00:00.445] [422ms] [2.3MB] transform -> ok(1247 records)
[03:00:01.003] [558ms] [2.5MB] validate -> err("schema mismatch")
[03:00:01.003] [0ms]   [2.5MB] upload -> skipped
```

For terse mode:

```
backup.rip: ✗ failed at validate (1.4s total)
  └─ err: schema mismatch: field 'email'
```

For error-only:

```
[03:00:01.003] validate -> err("schema mismatch: field 'email'", {
  duration: 558ms,
  input_rows: 1247,
  failed_at_row: 834,
  stack: [...],
  context: {db: "prod", table: "users"}
})
```

### Structured Logging

Since you're tracing everything, you could also support structured fields:

```ripple
!system::trace "verbose" {
  format: "json",
  include: ["duration", "memory", "result"],
  exclude: ["internal_state"]
}

// Produces:
// {"ts":"2025-10-22T03:00:00Z","dur":234,"mem":2100000,"expr":"fetch_data","result":{"ok":{"rows":1247}}}
```

This makes it easy to pipe into observability tools (Datadog, Grafana, etc.).

---

## Doc Module Extensions

```ripple
// Inline documentation for functions
backup_db := process::doc::fn {
  desc: "Backup a single database with compression",
  params: {db: "Database name"},
  returns: "ok(path) or err(reason)",
  side_effects: ["Writes to S3", "Sends metrics"]
} db ->
  process::run ["pg_dump", db]
    |> compress
    |> upload_to_s3

// Annotate critical sections
process::doc::critical "SLA: Must complete in < 5 minutes" {
  fetch_data
    |> transform
    |> upload
}

// Mark deprecated code
process::doc::deprecated "Use backup_db_v2 instead" {
  old_backup_logic
}
```

---

## Documentation Queries

If docs are structured data, you can query them:

```bash
# Find all scripts with a specific dependency
$ rvm doc --requires "postgresql"
backup.rip
health_check.rip

# Find scripts without on-call info
$ rvm doc --missing oncall
deploy.rip ⚠ No on-call specified

# Find scripts that violate SLA
$ rvm doc --sla-breach
backup.rip: Last run 6h 23m (SLA: 3h)

# Generate documentation site
$ rvm doc --export markdown
Writing docs to ./ripple-docs/
  backup.rip.md
  deploy.rip.md
  health_check.rip.md
```

---

## Doc Enforcement

You could make certain docs **required** for production scripts:

```ripple
!system::env "production"
!system::require_docs ["author", "oncall", "runbook"]

// Compile error if these are missing:
// error: production scripts must specify process::doc::author
```

---

## The Doc + Trace Combo

Here's where it gets powerful:

```ripple
process::doc::sla "Must complete in < 5 minutes"

!system::trace "verbose"
!system::on_sla_breach slack::alert "#ops" "SLA breach: backup took too long"

// The runtime knows the SLA from the doc
// and can enforce it automatically
```

Or:

```ripple
process::doc::invariant "result.success.length + result.failure.length == databases.length"

results := databases.parallel_map backup_db

// Runtime validates the invariant automatically
// If it fails, includes it in the trace:
// [03:00:05.000] invariant violation: expected 3 total, got 2
```

---

## Additional Directive Ideas

Since you're scanning for directives, here are some that might be useful:

```ripple
// Resource limits
!process::max_memory "2GB"
!process::max_cpu_percent 80

// Concurrency
!process::max_concurrent 5
!process::rate_limit "100/minute"

// Dependencies
!system::requires "postgresql >= 14"
!system::requires "aws-cli"

// Environments
!system::env "production"
!system::load_env ".env.production"

// Idempotency
!task::idempotent_key "backup-{date}"
!task::skip_if_recent "1h"

// Notifications
!system::on_success slack::notify "#ops" "Backup complete"
!system::on_failure pagerduty::alert "high"

// Retries with backoff
!system::retry {attempts: 3, backoff: "exponential"}
```

---

## Execution Model

The execution model is:

1. **Scan phase** — parse file, extract `!system::*`, `!process::*`, `!task::*`, `process::doc::*` directives
2. **Configure phase** — setup scheduler, logging, timeouts, failure handlers
3. **Execute phase** — run the actual logic with supervision + tracing

This means directives can't be dynamic (you can't compute a cron schedule). That's a good constraint — ops configs should be static and inspectable.

```ripple
// ✅ Valid - static directive
!system::schedule "0 3 * * *"

// ❌ Invalid - dynamic directive (compile error)
schedule := get_schedule_from_config()
!system::schedule schedule
```

---

## The Tracing Architecture

If every expression is auto-traced, you're building an **execution ledger** by default. That's powerful:

```ripple
// This trace is automatic, not opt-in
fetch_data
  |> transform
  |> validate
  |> upload

// Produces something like:
// [03:00:00.023] fetch_data -> ok(1247 rows, {duration: 234ms, mem: 2.1MB})
// [03:00:00.445] transform -> ok(1247 records, {duration: 422ms})
// [03:00:01.003] validate -> err("schema mismatch: field 'email'", {duration: 558ms})
// [03:00:01.003] upload -> skipped (pipeline short-circuited)
```

This makes **postmortem debugging** trivial. You know exactly which step failed, with what inputs, after what duration, at what timestamp.

### Trace Queries

```bash
rvm trace backup.rip --filter "duration > 1s"
rvm trace backup.rip --failed-only
rvm trace backup.rip --follow  # tail -f style
rvm trace backup.rip --replay   # re-run with same inputs
```

---

## Implementation Considerations

### Static vs Dynamic Boundary

**Question:** For `process::doc::*`, are these:
- **Evaluated expressions** that return doc objects?
- **Compile-time annotations** parsed during the scan phase?

**Recommendation:** Treat them as scan-phase annotations (like directives) so they're guaranteed to be static and extractable without execution.

```ripple
// Scan phase extracts these (static metadata)
process::doc::header "..."
process::doc::author "ops-team@company.com"
!system::schedule "..."

// Execution phase evaluates these (dynamic logic)
databases := fetch_databases()
results := backup(databases)
```

This creates a clean boundary:
- **Static metadata** = inspectable without running code
- **Dynamic logic** = requires execution

### Trace Storage

If everything is traced:
- How do you avoid I/O becoming the bottleneck?
- Async write-behind buffer?
- Sampling for high-frequency operations?
- Configurable trace levels per expression?

```ripple
// Maybe allow inline trace control?
!system::trace "terse"

// But override for specific sections
process::trace "debug" {
  critical_database_operation
}
```

---

## Bytecode Future Considerations

If you go bytecode eventually:
- **JIT-able?** Or pure interpretation of bytecode?
- **Portability** — single binary with embedded runtime?
- **Hot reload** — can you update a script without killing running instances?
- **Versioning** — if a script is scheduled to run in 6 hours, and you update it, which version runs?

---

## Self-Documenting Scripts

With auto-tracing + directive scanning, you could build **`rvm explain`**:

```bash
$ rvm explain backup.rip

Script: backup.rip
Purpose: Nightly database backups

Schedule: Daily at 03:00 UTC (0 3 * * *)
Timeout: 10 minutes
Concurrency: 3 parallel backups max

Dependencies:
  - pg_dump (PostgreSQL client)
  - AWS CLI (for S3 uploads)

Failure handling:
  - Email: ops@company.com
  - Retry: 3 attempts with exponential backoff

Last 5 executions:
  2025-10-22 03:00 ✓ success (4m 23s) - 3 databases backed up
  2025-10-21 03:00 ✓ success (4m 18s) - 3 databases backed up
  2025-10-20 03:00 ✗ failure (10m 0s) - timeout on 'prod' database
  2025-10-19 03:00 ✓ success (4m 31s) - 3 databases backed up
  2025-10-18 03:00 ✓ success (4m 27s) - 3 databases backed up
```

This would make Ripple scripts **self-documenting** in a way bash never could be.

---

## Additional RVM Commands

```bash
# Validation
rvm check backup.rip          # Syntax + directive validation
rvm check --env production    # Validate for specific environment

# Execution
rvm exec backup.rip           # One-time execution
rvm run backup.rip            # Supervised runtime
rvm daemon backup.rip         # Run as background daemon

# Monitoring
rvm logs backup.rip           # View logs
rvm logs backup.rip --follow  # Tail logs
rvm trace backup.rip          # Inspect execution trace
rvm status backup.rip         # Current status
rvm history backup.rip        # Execution history

# Documentation
rvm explain backup.rip        # Show full documentation
rvm doc --list                # List all documented scripts
rvm doc --export html         # Generate documentation site

# Debugging
rvm trace backup.rip --replay # Replay with same inputs
rvm trace backup.rip --debug  # Step-by-step execution
rvm test backup.rip           # Run script in test mode

# Management
rvm stop backup.rip           # Stop running script
rvm restart backup.rip        # Restart script
rvm enable backup.rip         # Enable scheduled execution
rvm disable backup.rip        # Disable scheduled execution
```
