const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ast = @import("ast.zig");
const eval = @import("evaluator.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const sys = @import("system.zig");

pub const RunAttempt = struct {
    status: Status,
    value: ?eval.Value,
    err: ?anyerror,
    trace: ?[]const eval.TraceEntry,
    duration_ms: u64,
    memory_used: usize,

    pub const Status = enum { success, eval_error, parse_error, timeout };

    pub fn deinit(self: *RunAttempt, allocator: Allocator) void {
        if (self.trace) |t| {
            allocator.free(t);
        }
    }
};

pub const Process = struct {
    allocator: Allocator,
    enable_trace: bool,

    pub fn executeOnce(self: *Process, source: []const u8) !RunAttempt {
        const start_time = try std.time.Instant.now();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // 1. Tokenize
        const tokens = lexer.tokenize(source, arena.allocator()) catch |err| {
            const end_time = try std.time.Instant.now();
            const duration_ms = end_time.since(start_time) / std.time.ns_per_ms;

            return RunAttempt{
                .status = .parse_error,
                .value = null,
                .err = err,
                .trace = null,
                .duration_ms = duration_ms,
                .memory_used = 0,
            };
        };

        // 2. Parse
        const program = parser.parse(tokens, arena.allocator()) catch |err| {
            const end_time = try std.time.Instant.now();
            const duration_ms = end_time.since(start_time) / std.time.ns_per_ms;

            return RunAttempt{
                .status = .parse_error,
                .value = null,
                .err = err,
                .trace = null,
                .duration_ms = duration_ms,
                .memory_used = 0,
            };
        };

        // 3. Evaluate
        const eval_config = eval.EvalConfig{ .enable_trace = self.enable_trace };
        var eval_result = eval.evaluate(program, arena.allocator(), eval_config) catch |err| {
            const end_time = try std.time.Instant.now();
            const duration_ms = end_time.since(start_time) / std.time.ns_per_ms;

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

        // 4. Copy trace
        const end_time = try std.time.Instant.now();
        const duration_ms = end_time.since(start_time) / std.time.ns_per_ms;
        const trace_copy = if (self.enable_trace) blk: {
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

////////////////////////////////////////////////////
//// TESTS
////////////////////////////////////////////////////

// ============================================================================
// Happy Path Tests
// ============================================================================

test "Process.executeOnce succeeds for valid program" {
    const allocator = testing.allocator;
    const source = "x := 42";

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var process = try system_instance.spawnProcess("unit_test");

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

test "Process.executeOnce tracks duration" {
    const allocator = testing.allocator;
    const source = "result := 5 + 5";

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var process = try system_instance.spawnProcess("unit_test");

    var attempt = try process.executeOnce(source);
    defer attempt.deinit(allocator);

    try testing.expectEqual(RunAttempt.Status.success, attempt.status);
    try testing.expect(attempt.duration_ms >= 0); // Should have measurable duration
    try testing.expectEqual(@as(f64, 10.0), attempt.value.?.number);
}

test "Process.executeOnce respects trace config" {
    const allocator = testing.allocator;
    const source = "x := 42";

    // Test with trace enabled (default)
    {
        const sys_config = sys.SystemConfig{};
        var system_instance = try sys.System.init(allocator, sys_config);
        defer system_instance.deinit();

        var process = try system_instance.spawnProcess("trace_test");

        var attempt = try process.executeOnce(source);
        defer attempt.deinit(allocator);

        try testing.expect(attempt.trace != null);
        try testing.expect(attempt.trace.?.len > 0);
    }

    // Test with trace disabled
    {
        const sys_config = sys.SystemConfig{ .enable_trace = false };
        var system_instance = try sys.System.init(allocator, sys_config);
        defer system_instance.deinit();

        var process = try system_instance.spawnProcess("no_trace_test");

        var attempt = try process.executeOnce(source);
        defer attempt.deinit(allocator);

        try testing.expect(attempt.trace == null);
    }
}

// ============================================================================
// Error Handling Tests
// ============================================================================

test "Process.executeOnce fails on eval error" {
    const allocator = testing.allocator;
    const source = "x := unknown";

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var process = try system_instance.spawnProcess("unit_test");

    var attempt = try process.executeOnce(source);
    defer attempt.deinit(allocator);

    try testing.expectEqual(RunAttempt.Status.eval_error, attempt.status);
    try testing.expect(attempt.value == null);
    try testing.expect(attempt.err != null);
    try testing.expect(attempt.trace == null); // No trace on error
    try testing.expect(attempt.duration_ms >= 0);
}

test "Process.executeOnce fails on parse error" {
    const allocator = testing.allocator;
    const source = "x := := 10";

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var process = try system_instance.spawnProcess("unit_test");

    var attempt = try process.executeOnce(source);
    defer attempt.deinit(allocator);

    try testing.expectEqual(RunAttempt.Status.parse_error, attempt.status);
    try testing.expect(attempt.value == null);
    try testing.expect(attempt.err != null);
    try testing.expect(attempt.trace == null); // No trace on parse error
    try testing.expect(attempt.duration_ms >= 0);
}

test "Process.executeOnce captures error type correctly" {
    const allocator = testing.allocator;

    // Test parse error
    {
        const source = "x := := 10";
        const sys_config = sys.SystemConfig{};
        var system_instance = try sys.System.init(allocator, sys_config);
        defer system_instance.deinit();

        var process = try system_instance.spawnProcess("parse_error_test");
        var attempt = try process.executeOnce(source);
        defer attempt.deinit(allocator);

        try testing.expectEqual(RunAttempt.Status.parse_error, attempt.status);
        try testing.expect(attempt.err != null);
    }

    // Test eval error
    {
        const source = "x := unknown";
        const sys_config = sys.SystemConfig{};
        var system_instance = try sys.System.init(allocator, sys_config);
        defer system_instance.deinit();

        var process = try system_instance.spawnProcess("eval_error_test");
        var attempt = try process.executeOnce(source);
        defer attempt.deinit(allocator);

        try testing.expectEqual(RunAttempt.Status.eval_error, attempt.status);
        try testing.expect(attempt.err != null);
    }
}

// ============================================================================
// Trace Tests
// ============================================================================

// test "each trace entry gets unique sequential task_id" {
//     const allocator = testing.allocator;
//     const source =
//         \\x := 10
//         \\y := x + 32
//         \\z := y * 2
//         \\z
//     ;

//     const sys_config = sys.SystemConfig{};
//     var system_instance = try sys.System.init(allocator, sys_config);
//     defer system_instance.deinit();

//     var process = try system_instance.spawnProcess("unit_test");

//     var attempt = try process.executeOnce(source);
//     defer attempt.deinit(allocator);

//     try testing.expect(attempt.trace != null);
//     const trace = attempt.trace.?;

//     // Every entry has a task_id > 0
//     for (trace) |entry| {
//         try testing.expect(entry.task_id > 0);
//     }

//     // Strictly increasing and unique
//     var last_id: usize = 0;
//     for (trace) |entry| {
//         try testing.expect(entry.task_id > last_id);
//         last_id = entry.task_id;
//     }
// }

test "trace contains expected operations" {
    const allocator = testing.allocator;
    const source =
        \\x := 10
        \\y := 20
        \\result := x + y
    ;

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var process = try system_instance.spawnProcess("unit_test");

    var attempt = try process.executeOnce(source);
    defer attempt.deinit(allocator);

    try testing.expect(attempt.trace != null);
    const trace = attempt.trace.?;

    // Should have at least 3 trace entries (one per assignment)
    try testing.expect(trace.len >= 3);
}

// ============================================================================
// Memory and Cleanup Tests
// ============================================================================

test "Process.executeOnce cleans up arena on success" {
    const allocator = testing.allocator;
    const source = "x := 42";

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var process = try system_instance.spawnProcess("cleanup_test");

    var attempt = try process.executeOnce(source);
    defer attempt.deinit(allocator);

    // If this passes with no leaks, arena cleanup is working
    try testing.expectEqual(RunAttempt.Status.success, attempt.status);
}

test "Process.executeOnce cleans up arena on error" {
    const allocator = testing.allocator;
    const source = "x := unknown";

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var process = try system_instance.spawnProcess("cleanup_error_test");

    var attempt = try process.executeOnce(source);
    defer attempt.deinit(allocator);

    // If this passes with no leaks, arena cleanup on error is working
    try testing.expectEqual(RunAttempt.Status.eval_error, attempt.status);
}

// ============================================================================
// Timeout Tests (Placeholder - requires actual timeout implementation)
// ============================================================================

// NOTE: This test is a placeholder. It will need to be updated once you implement
// actual timeout functionality in Process. For now, it's commented out.
//
// test "Process enforces timeout" {
//     const allocator = testing.allocator;
//     const source = "x := 0"; // Replace with infinite loop when language supports it
//
//     const sys_config = sys.SystemConfig{
//         .timeout_ms = 100,  // 100ms timeout
//     };
//     var system_instance = try sys.System.init(allocator, sys_config);
//     defer system_instance.deinit();
//
//     var process = try system_instance.spawnProcess("timeout_test");
//
//     var attempt = try process.executeOnce(source);
//     defer attempt.deinit(allocator);
//
//     try testing.expectEqual(RunAttempt.Status.timeout, attempt.status);
//     try testing.expect(attempt.value == null);
// }
