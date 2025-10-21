const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ast = @import("ast.zig");
const eval = @import("evaluator.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

pub const System = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) System {
        return System{ .allocator = allocator };
    }

    pub fn spawnProcess(self: *System, name: []const u8, config: SupervisorConfig) Process {
        return Process{
            .system = self,
            .name = name,
            .config = config,
        };
    }
};

pub const Process = struct {
    system: *System,
    name: []const u8,
    config: SupervisorConfig,
    next_task_id: usize = 1,

    pub fn nextTaskId(self: *Process) usize {
        const id = self.next_task_id;
        self.next_task_id += 1;
        return id;
    }

    pub fn executeOnce(self: *Process, source: []const u8) !RunAttempt {
        const start_time = try std.time.Instant.now();

        // Use the system allocator (we’ll refine this later)
        var arena = std.heap.ArenaAllocator.init(self.system.allocator);
        defer arena.deinit();

        const tokens = lexer.tokenize(source, arena.allocator()) catch |err| {
            const end_time = try std.time.Instant.now();
            const duration_ns = end_time.since(start_time);
            return RunAttempt{
                .status = .parse_error,
                .value = null,
                .err = err,
                .trace = null,
                .duration_ms = duration_ns / std.time.ns_per_ms,
                .memory_used = 0,
            };
        };

        const program = parser.parse(tokens, arena.allocator()) catch |err| {
            const end_time = try std.time.Instant.now();
            const duration_ns = end_time.since(start_time);
            return RunAttempt{
                .status = .parse_error,
                .value = null,
                .err = err,
                .trace = null,
                .duration_ms = duration_ns / std.time.ns_per_ms,
                .memory_used = 0,
            };
        };

        const eval_config = eval.EvalConfig{ .enable_trace = self.config.enable_trace };
        var eval_result = eval.evaluate(program, arena.allocator(), eval_config) catch |err| {
            const end_time = try std.time.Instant.now();
            const duration_ns = end_time.since(start_time);
            return RunAttempt{
                .status = .eval_error,
                .value = null,
                .err = err,
                .trace = null,
                .duration_ms = duration_ns / std.time.ns_per_ms,
                .memory_used = 0,
            };
        };
        defer eval_result.deinit();

        const end_time = try std.time.Instant.now();
        const duration_ns = end_time.since(start_time);
        const duration_ms = duration_ns / std.time.ns_per_ms;

        // Copy trace and assign task IDs
        const trace_copy = if (self.config.enable_trace) blk: {
            const copy = try self.system.allocator.alloc(eval.TraceEntry, eval_result.trace.len);
            @memcpy(copy, eval_result.trace);
            for (copy) |*entry| {
                entry.task_id = self.nextTaskId();
            }
            break :blk copy;
        } else null;

        return RunAttempt{
            .status = .success,
            .value = eval_result.value,
            .err = null,
            .trace = trace_copy,
            .duration_ms = duration_ms,
            .memory_used = 0,
        };
    }
};

// ============================================================================
// Configuration
// ============================================================================

pub const SupervisorConfig = struct {
    max_restarts: u32 = 3,
    timeout_ms: ?u64 = null,
    enable_trace: bool = true,
};

// ============================================================================
// Internal Types (used by Supervisor implementation)
// ============================================================================

const RunAttempt = struct {
    status: Status,
    value: ?eval.Value,
    err: ?anyerror,
    trace: ?[]const eval.TraceEntry,
    duration_ms: u64,
    memory_used: usize,

    pub const Status = enum { success, eval_error, parse_error };

    pub fn deinit(self: *RunAttempt, allocator: Allocator) void {
        if (self.trace) |t| {
            allocator.free(t);
        }
    }
};

// ============================================================================
// Public Result Type
// ============================================================================

pub const SupervisionResult = struct {
    status: Status,
    attempts: u32,
    final_value: ?eval.Value,
    trace: ?[]const eval.TraceEntry,
    duration_ms: u64,
    memory_used: usize,
    last_error: ?anyerror,
    allocator: Allocator,

    pub const Status = enum {
        success,
        failed_max_restarts,
        eval_error,
        parse_error,
        timeout,
    };

    pub fn deinit(self: *SupervisionResult) void {
        if (self.trace) |t| {
            self.allocator.free(t);
        }
    }
};

// ============================================================================
// Supervisor
// ============================================================================

pub const Supervisor = struct {
    allocator: Allocator,
    config: SupervisorConfig,

    // ========================================================================
    // Public API
    // ========================================================================

    pub fn run(self: *Supervisor, source: []const u8) !SupervisionResult {
        var system = System.init(self.allocator);
        var process = system.spawnProcess("main", self.config);

        var total_duration: u64 = 0;
        var attempt: u32 = 1;

        while (attempt <= self.config.max_restarts) : (attempt += 1) {
            var result = try process.executeOnce(source);
            total_duration += result.duration_ms;

            // Guard: Success - return immediately
            if (result.status == .success) {
                return SupervisionResult{
                    .allocator = self.allocator,
                    .attempts = attempt,
                    .duration_ms = total_duration,
                    .final_value = result.value,
                    .last_error = null,
                    .memory_used = 0,
                    .status = .success,
                    .trace = result.trace,
                };
            }

            // Guard: Parse error - don't retry
            if (result.status == .parse_error) {
                return SupervisionResult{
                    .allocator = self.allocator,
                    .attempts = attempt,
                    .duration_ms = total_duration,
                    .final_value = null,
                    .last_error = result.err,
                    .memory_used = 0,
                    .status = .parse_error,
                    .trace = result.trace,
                };
            }

            // Guard: Last attempt with eval error - exhausted retries
            if (result.status == .eval_error and attempt == self.config.max_restarts) {
                return SupervisionResult{
                    .allocator = self.allocator,
                    .attempts = attempt,
                    .duration_ms = total_duration,
                    .final_value = null,
                    .last_error = result.err,
                    .memory_used = 0,
                    .status = .failed_max_restarts,
                    .trace = result.trace,
                };
            }

            // Implicit: eval_error but not last attempt - free and retry
            result.deinit(self.allocator);
        }

        unreachable;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Supervisor.attemptRun succeeds for valid program" {
    const allocator = testing.allocator;
    const source = "x := 42";

    const config = SupervisorConfig{};
    var system = System.init(allocator);
    var process = system.spawnProcess("test", config);

    var attempt = try process.executeOnce(source);
    defer attempt.deinit(allocator);

    try testing.expectEqual(RunAttempt.Status.success, attempt.status);
    try testing.expect(attempt.value != null);
    try testing.expectEqual(@as(f64, 42.0), attempt.value.?.number);
    try testing.expect(attempt.err == null);
    try testing.expect(attempt.trace != null);
    try testing.expect(attempt.trace.?.len > 0);
    try testing.expect(attempt.duration_ms >= 0);
}

test "Supervisor.attemptRun fails on eval error" {
    const allocator = testing.allocator;
    const source = "x := unknown";

    const config = SupervisorConfig{};
    var system = System.init(allocator);
    var process = system.spawnProcess("test", config);

    var attempt = try process.executeOnce(source);
    defer attempt.deinit(allocator);

    try testing.expectEqual(RunAttempt.Status.eval_error, attempt.status);
    try testing.expect(attempt.value == null);
    try testing.expect(attempt.err != null);
    try testing.expect(attempt.trace == null);
    try testing.expect(attempt.duration_ms >= 0);
}

test "Supervisor.attemptRun fails on parse error" {
    const allocator = testing.allocator;
    const source = "x := := 10";

    const config = SupervisorConfig{};
    var system = System.init(allocator);
    var process = system.spawnProcess("test", config);

    var attempt = try process.executeOnce(source);
    defer attempt.deinit(allocator);

    try testing.expectEqual(RunAttempt.Status.parse_error, attempt.status);
    try testing.expect(attempt.value == null);
    try testing.expect(attempt.err != null);
    try testing.expect(attempt.trace == null);
    try testing.expect(attempt.duration_ms >= 0);
}

test "supervisor runs simple program successfully" {
    const allocator = testing.allocator;
    const source = "x := 42";

    const config = SupervisorConfig{
        .max_restarts = 3,
        .enable_trace = true,
    };

    var supervisor = Supervisor{
        .allocator = allocator,
        .config = config,
    };

    var result = try supervisor.run(source);
    defer result.deinit();

    try testing.expectEqual(SupervisionResult.Status.success, result.status);
    try testing.expectEqual(@as(u32, 1), result.attempts);
    try testing.expect(result.final_value != null);
    try testing.expectEqual(@as(f64, 42.0), result.final_value.?.number);
    try testing.expect(result.last_error == null);
    try testing.expect(result.trace != null);
    try testing.expect(result.trace.?.len > 0);
}

test "supervisor exhausts max retries" {
    const allocator = testing.allocator;
    const source = "z := unknown";

    const config = SupervisorConfig{ .max_restarts = 3 };
    var supervisor = Supervisor{ .allocator = allocator, .config = config };

    var result = try supervisor.run(source);
    defer result.deinit();

    try testing.expectEqual(SupervisionResult.Status.failed_max_restarts, result.status);
    try testing.expectEqual(@as(u32, 3), result.attempts);
    try testing.expect(result.final_value == null);
    try testing.expect(result.last_error != null);
}

test "supervisor multiplication works" {
    const allocator = testing.allocator;
    const source = "result := 3 * 4";

    const config = SupervisorConfig{ .enable_trace = true };
    var supervisor = Supervisor{ .allocator = allocator, .config = config };

    var result = try supervisor.run(source);
    defer result.deinit();

    try testing.expectEqual(SupervisionResult.Status.success, result.status);
    try testing.expectEqual(@as(f64, 12.0), result.final_value.?.number);
}

//////////////////////////
//// Tests
//////////////////////////

test "each trace entry gets unique sequential task_id" {
    const allocator = testing.allocator;
    const source =
        \\x := 10
        \\y := x + 32
        \\z := y * 2
        \\z
    ;

    const config = SupervisorConfig{
        .enable_trace = true,
    };

    var supervisor = Supervisor{
        .allocator = allocator,
        .config = config,
    };

    var result = try supervisor.run(source);
    defer result.deinit();

    try testing.expect(result.trace != null);
    const trace = result.trace.?;

    // every entry has a task_id > 0
    for (trace) |entry| {
        try testing.expect(entry.task_id > 0);
    }

    // strictly increasing and unique
    var last_id: usize = 0;
    for (trace) |entry| {
        try testing.expect(entry.task_id > last_id);
        last_id = entry.task_id;
    }
}

test "Process enforces timeout" {
    const allocator = testing.allocator;

    // This "script" simulates a long-running expression
    // Replace with an expression your evaluator will hang or sleep on.
    const source = "x := 0"; // We'll simulate delay below instead of relying on real script

    const config = SupervisorConfig{
        .timeout_ms = 50, // 50 ms timeout
    };

    var system = System.init(allocator);
    var process = system.spawnProcess("timeout_test", config);

    // Simulate slow evaluation: wrap evaluate() call in artificial delay
    var attempt = try process.executeOnce(source);
    defer attempt.deinit(allocator);

    try testing.expectEqual(RunAttempt.Status.timeout, attempt.status);
    try testing.expect(attempt.value == null);
    try testing.expect(attempt.err == null);
}

test "Process enforces timeout for long-running evaluation" {
    const allocator = testing.allocator;

    // NOTE: This source is a test sentinel. In your implementation,
    // under test builds, detect this exact string and simulate slow
    // evaluation (e.g., sleep ~200ms inside evaluate or a test-only hook).
    // That keeps production semantics unchanged while giving us a deterministic
    // long-running eval for the watchdog to trip.
    const source = "__SLOW_EVAL__";

    const config = SupervisorConfig{
        .timeout_ms = 50, // 50ms budget
        .enable_trace = true, // keep whatever default you want here
    };

    var system = System.init(allocator);
    var process = system.spawnProcess("timeout_test", config);

    var attempt = try process.executeOnce(source);
    defer attempt.deinit(allocator);

    // NEW behavior we’re specifying now:
    // - RunAttempt gains a `.timeout` status
    // - On timeout: no value, no error (policy choice), trace may be partial or null
    try testing.expectEqual(RunAttempt.Status.timeout, attempt.status);
    try testing.expect(attempt.value == null);
    try testing.expect(attempt.err == null);
    try testing.expect(attempt.duration_ms >= config.timeout_ms.?);
}
