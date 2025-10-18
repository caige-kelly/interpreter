const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("evaluator.zig").Value;
const EvalResult = @import("evaluator.zig").EvalResult;

const RunAttempt = struct {
    status: Status,
    value: ?Value,
    err: ?anyerror,
    trace: []const EvalResult, // Allocated, caller must free
    duration_ms: u64,
    memory_used: usize, // Always 0 for now (TODO: add tracking)

    pub const Status = enum {
        success,
        eval_error,
        parse_error,
    };

    pub fn deinit(self: *RunAttempt, allocator: Allocator) void {
        allocator.free(self.trace);
    }
};

pub const SupervisorConfig = struct {
    max_restarts: u32 = 3,
    timeout_ms: ?u64 = null,
    enable_trace: bool = true,
};

pub const SupervisionResult = struct {
    status: Status,
    attempts: u32,
    final_value: ?Value,
    trace: []const EvalResult,
    duration_ms: u64,
    memory_used: usize,
    last_error: ?anyerror,
    allocator: Allocator, // Need this for deinit

    pub const Status = enum {
        success,
        failed_max_restarts,
        parse_error,
        timeout,
    };

    pub fn deinit(self: *SupervisionResult) void {
        // TODO: Free trace array
        _ = self;
    }
};

pub const Supervisor = struct {
    allocator: Allocator,
    config: SupervisorConfig,

    pub fn init(allocator: Allocator, config: SupervisorConfig) !Supervisor {
        return Supervisor{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Supervisor) void {
        _ = self;
        // Nothing to clean up yet
    }

    pub fn run(self: *Supervisor, source: []const u8) !SupervisionResult {
        _ = self;
        _ = source;
        return error.NotImplemented;
    }
};

// Tests at the bottom (Zig style)
const testing = std.testing;

test "supervisor runs simple program successfully" {
    const allocator = testing.allocator;
    const source = "x := 42";

    const config = SupervisorConfig{
        .max_restarts = 3,
        .enable_trace = true,
    };

    var supervisor = try Supervisor.init(allocator, config);
    defer supervisor.deinit();

    var result = try supervisor.run(source);
    defer result.deinit();

    // Should succeed on first attempt
    try testing.expectEqual(SupervisionResult.Status.success, result.status);
    try testing.expectEqual(@as(u32, 1), result.attempts);

    // Should have a value
    try testing.expect(result.final_value != null);

    // Should have no error
    try testing.expect(result.last_error == null);

    // Should have trace (if enabled)
    try testing.expect(result.trace.len > 0);
}

test "Supervisor.attemptRun succeeds for valid program" {
    const allocator = testing.allocator;
    const source = "x := 42";

    const config = SupervisorConfig{};
    var supervisor = try Supervisor.init(allocator, config);
    defer supervisor.deinit();

    var attempt = try supervisor.attemptRun(source);
    defer attempt.deinit(allocator);

    // Should succeed
    try testing.expectEqual(RunAttempt.Status.success, attempt.status);
    try testing.expect(attempt.value != null);
    try testing.expectEqual(Value{ .number = 42.0 }, attempt.value.?);

    // Should have no error
    try testing.expect(attempt.err == null);

    // Should have trace (config defaults to enable_trace=true)
    try testing.expect(attempt.trace.len > 0);
}
