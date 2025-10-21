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

    pub fn attempt(self: *Process, source: []const u8) !RunAttempt {
        // Temporarily just call the Supervisor's private function.
        // We’ll move this body here later in Step 2.
        var temp_supervisor = Supervisor{
            .allocator = self.system.allocator,
            .config = self.config,
        };
        return temp_supervisor.attemptRun(source);
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
            var result = try process.attempt(source);
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

    // ========================================================================
    // Internal Implementation (unit tested)
    // ========================================================================

    fn attemptRun(self: *Supervisor, source: []const u8) !RunAttempt {
        const start_time = try std.time.Instant.now();

        // Arena for temporary allocations
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // Try tokenization
        const tokens = lexer.tokenize(source, arena.allocator()) catch |err| {
            const end_time = try std.time.Instant.now();
            const duration_ns = end_time.since(start_time);
            const duration_ms = duration_ns / std.time.ns_per_ms;

            return RunAttempt{
                .status = .parse_error,
                .value = null,
                .err = err,
                .trace = null,
                .duration_ms = duration_ms,
                .memory_used = 0,
            };
        };

        // Try parsing
        const program = parser.parse(tokens, arena.allocator()) catch |err| {
            const end_time = try std.time.Instant.now();
            const duration_ns = end_time.since(start_time);
            const duration_ms = duration_ns / std.time.ns_per_ms;

            return RunAttempt{
                .status = .parse_error,
                .value = null,
                .err = err,
                .trace = null,
                .duration_ms = duration_ms,
                .memory_used = 0,
            };
        };

        // Try evaluation
        const eval_config = eval.EvalConfig{ .enable_trace = self.config.enable_trace };
        var eval_result = eval.evaluate(program, arena.allocator(), eval_config) catch |err| {
            const end_time = try std.time.Instant.now();
            const duration_ns = end_time.since(start_time);
            const duration_ms = duration_ns / std.time.ns_per_ms;

            return RunAttempt{
                .status = .eval_error,
                .value = null,
                .err = err,
                .trace = null,
                .duration_ms = duration_ms,
                .memory_used = 0,
            };
        };
        defer eval_result.deinit();

        // Success - measure time and copy trace to permanent memory
        const end_time = try std.time.Instant.now();
        const duration_ns = end_time.since(start_time);
        const duration_ms = duration_ns / std.time.ns_per_ms;

        // Copy trace to permanent memory
        const trace_copy = if (self.config.enable_trace) blk: {
            const copy = try self.allocator.alloc(eval.TraceEntry, eval_result.trace.len);
            @memcpy(copy, eval_result.trace);
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
// Tests
// ============================================================================

test "Supervisor.attemptRun succeeds for valid program" {
    const allocator = testing.allocator;
    const source = "x := 42";

    const config = SupervisorConfig{};
    var supervisor = Supervisor{
        .allocator = allocator,
        .config = config,
    };

    var attempt = try supervisor.attemptRun(source);
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
    var supervisor = Supervisor{
        .allocator = allocator,
        .config = config,
    };

    var attempt = try supervisor.attemptRun(source);
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
    var supervisor = Supervisor{
        .allocator = allocator,
        .config = config,
    };

    var attempt = try supervisor.attemptRun(source);
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
