const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const eval = @import("evaluator.zig");

pub const SupervisorConfig = struct {
    max_restarts: u32 = 3,
    timeout_ms: ?u64 = null,
    enable_trace: bool = true,
};

pub const SupervisionResult = struct {
    status: Status,
    attempts: u32,
    final_value: ?eval.Value,
    trace: []const eval.EvalResult,
    duration_ms: u64,
    memory_used: usize,
    last_error: ?anyerror,
    allocator: Allocator, // Need this for deinit

    pub const Status = enum {
        evaluation_failure,
        lexer_failure,
        parser_failure,
        success,
        failed_max_restarts,
        parse_error,
        timeout,
    };

    pub fn deinit(self: *SupervisionResult) void {
        self.allocator.free(self.trace);
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
        var allocator = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = allocator.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator.allocator());
        defer _ = arena.deinit();

        // 1. Lex
        var l = try lexer.Lexer.init(source, arena.allocator());
        defer _ = l.deinit();
        const tokens = try l.scanTokens();

        // 2. Parse
        var p = try parser.Parser.init(tokens, arena.allocator());
        defer _ = p.deinit();
        const program = try p.parse();

        // 3. Evaluate ← NEW!
        const eval_config = eval.EvalConfig{ .enable_trace = self.config.enable_trace };
        var evaluator = try eval.Evaluator.init(arena.allocator(), eval_config);
        const result = evaluator.evaluate(program) catch |res| {
            switch (res) {
                error.ExpressionDontExist => |err| {
                    return SupervisionResult{ .status = SupervisionResult.Status.evaluation_failure, .attempts = 1, .duration_ms = 0, .trace = evaluator.get_trace(), .memory_used = 0, .last_error = err, .final_value = null, .allocator = self.allocator };
                },
                error.OutOfMemory => |err| {
                    return SupervisionResult{ .status = SupervisionResult.Status.evaluation_failure, .attempts = 1, .duration_ms = 0, .trace = evaluator.get_trace(), .memory_used = 0, .last_error = err, .final_value = null, .allocator = self.allocator };
                },
                error.UndefinedVariable => |err| {
                    return SupervisionResult{ .status = SupervisionResult.Status.evaluation_failure, .attempts = 1, .duration_ms = 0, .trace = evaluator.get_trace(), .memory_used = 0, .last_error = err, .final_value = null, .allocator = self.allocator };
                },
                error.VariableAlreadyDefined => |err| {
                    return SupervisionResult{ .status = SupervisionResult.Status.evaluation_failure, .attempts = 1, .duration_ms = 0, .trace = evaluator.get_trace(), .memory_used = 0, .last_error = err, .final_value = null, .allocator = self.allocator };
                },
            }
        };

        return SupervisionResult{ .attempts = 1, .duration_ms = 0, .memory_used = 0, .final_value = result, .status = SupervisionResult.Status.success, .trace = evaluator.get_trace(), .last_error = null, .allocator = self.allocator };
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

    var attempt = try supervisor.run(source);
    defer attempt.deinit();

    // Should succeed
    try testing.expectEqual(SupervisionResult.Status.success, attempt.status);
    try testing.expect(attempt.final_value != null);
    try testing.expectEqual(eval.Value{ .number = 42.0 }, attempt.final_value.?);

    // Should have no error
    try testing.expect(attempt.err.? == null);

    // Should have trace (config defaults to enable_trace=true)
    try testing.expect(attempt.trace.len > 0);
}
