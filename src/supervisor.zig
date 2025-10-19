const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ast = @import("ast.zig");
const eval = @import("evaluator.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

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
    trace: ?[]const eval.EvalResult,
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
    trace: ?[]const eval.EvalResult,
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
        var total_duration: u64 = 0;
        var attempt: u32 = 1;

        while (attempt <= self.config.max_restarts) : (attempt += 1) {
            var result = try self.attemptRun(source);
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

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer _ = arena.deinit();

        // 1. Lex
        var l = try lexer.Lexer.init(source, arena.allocator());
        defer _ = l.deinit();
        const tokens = try l.scanTokens();

        // 2. Parse
        var p = try parser.Parser.init(tokens, arena.allocator());
        defer _ = p.deinit();
        var program = p.parse() catch |err| {
            return self.finishAttempt(start_time, .parse_error, null, err, null);
        };
        defer program.deinit();

        // 3. Evaluate ← NEW!
        var evaluator = try eval.Evaluator.init(arena.allocator(), .{ .enable_trace = true });
        defer _ = evaluator.deinit();
        const result = evaluator.evaluate(program) catch |err| {
            return self.finishAttempt(start_time, .eval_error, null, err, &evaluator);
        };
        return self.finishAttempt(start_time, .success, result, null, &evaluator);
    }

    // -------------------------------------------------------------
    // Utility functions
    // -------------------------------------------------------------

    fn copyTrace(self: *Supervisor, temp_trace: []const eval.EvalResult) ![]const eval.EvalResult {
        const trace_copy = try self.allocator.alloc(eval.EvalResult, temp_trace.len);
        //defer self.allocator.free(temp_trace);
        @memcpy(trace_copy, temp_trace);
        return trace_copy;
    }

    fn finishAttempt(
        self: *Supervisor,
        start_time: std.time.Instant,
        status: RunAttempt.Status,
        value: ?eval.Value,
        err: ?anyerror,
        evaluator: ?*eval.Evaluator, // null for parse errors (no evaluator yet)
    ) !RunAttempt {
        const end_time = try std.time.Instant.now();
        const duration_ns = end_time.since(start_time);
        const duration_ms = duration_ns / std.time.ns_per_ms;

        const trace_copy = if (self.config.enable_trace and evaluator != null)
            try self.copyTrace(evaluator.?.get_trace())
        else
            null;

        return RunAttempt{
            .status = status,
            .value = value,
            .err = err,
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

    // Should succeed
    try testing.expectEqual(RunAttempt.Status.success, attempt.status);
    try testing.expect(attempt.value != null);
    try testing.expectEqual(eval.Value{ .number = 42.0 }, attempt.value.?);

    // Should have no error
    try testing.expect(attempt.err == null);

    // Should have trace (config defaults to enable_trace=true)
    try testing.expect(attempt.trace.?.len > 0);

    // Duration should be measured
    try testing.expect(attempt.duration_ms >= 0);
}

test "Supervisor.attemptRun fails on eval error" {
    const allocator = testing.allocator;
    const source = "x := unknown"; // Undefined variable

    const config = SupervisorConfig{};
    var supervisor = Supervisor{
        .allocator = allocator,
        .config = config,
    };

    var attempt = try supervisor.attemptRun(source);
    defer attempt.deinit(allocator);

    // Should fail with eval error
    try testing.expectEqual(RunAttempt.Status.eval_error, attempt.status);
    try testing.expect(attempt.value == null);
    try testing.expect(attempt.err != null);

    // Should have trace (evaluation started, then failed)
    try testing.expect(attempt.trace != null);

    // Duration should be measured
    try testing.expect(attempt.duration_ms >= 0);
}

test "Supervisor.attemptRun fails on parse error" {
    const allocator = testing.allocator;
    const source = "x := := 10"; // Syntax error

    const config = SupervisorConfig{};
    var supervisor = Supervisor{
        .allocator = allocator,
        .config = config,
    };

    var attempt = try supervisor.attemptRun(source);
    defer attempt.deinit(allocator);

    // Should fail with parse error
    try testing.expectEqual(RunAttempt.Status.parse_error, attempt.status);
    try testing.expect(attempt.value == null);
    try testing.expect(attempt.err != null);

    // Should have NO trace (never got to evaluation)
    try testing.expect(attempt.trace == null);

    // Duration should be measured
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

    // Should succeed on first attempt
    try testing.expectEqual(SupervisionResult.Status.success, result.status);
    try testing.expectEqual(@as(u32, 1), result.attempts);

    // Should have a value
    try testing.expect(result.final_value != null);
    try testing.expectEqual(eval.Value{ .number = 42.0 }, result.final_value.?);

    // Should have no error
    try testing.expect(result.last_error == null);

    // Should have trace (if enabled)
    try testing.expect(result.trace.?.len > 0);
}

test "supervisor exhausts max retries" {
    const allocator = testing.allocator;
    const source = "z := unknown";

    const config = SupervisorConfig{ .max_restarts = 3 };
    var supervisor = Supervisor{ .allocator = allocator, .config = config };

    var result = try supervisor.run(source);
    defer result.deinit();

    // Should fail after 3 attempts
    try testing.expectEqual(SupervisionResult.Status.failed_max_restarts, result.status);
    try testing.expectEqual(@as(u32, 3), result.attempts);
    try testing.expect(result.final_value == null);
    try testing.expect(result.last_error != null);
}
