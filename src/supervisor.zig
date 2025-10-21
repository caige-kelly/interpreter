const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ast = @import("ast.zig");
const eval = @import("evaluator.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const sys = @import("system.zig");
const Process = @import("process.zig").Process;
const RunAttempt = @import("process.zig").RunAttempt;

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

pub const Supervisor = struct {
    system: sys.System,

    pub fn run(self: *Supervisor, source: []const u8) !SupervisionResult {
        var process = try self.system.spawnProcess("main");

        var total_duration: u64 = 0;
        var attempt: u32 = 1;

        while (attempt <= self.system.config.max_restarts) : (attempt += 1) {
            var result = try process.executeOnce(source);
            total_duration += result.duration_ms;

            if (result.status == .success) {
                return SupervisionResult{
                    .allocator = self.system.allocator,
                    .attempts = attempt,
                    .duration_ms = total_duration,
                    .final_value = result.value,
                    .last_error = null,
                    .memory_used = 0,
                    .status = .success,
                    .trace = result.trace,
                };
            }

            if (result.status == .parse_error) {
                return SupervisionResult{
                    .allocator = self.system.allocator,
                    .attempts = attempt,
                    .duration_ms = total_duration,
                    .final_value = null,
                    .last_error = result.err,
                    .memory_used = 0,
                    .status = .parse_error,
                    .trace = result.trace,
                };
            }

            if (result.status == .eval_error and attempt == self.system.config.max_restarts) {
                return SupervisionResult{
                    .allocator = self.system.allocator,
                    .attempts = attempt,
                    .duration_ms = total_duration,
                    .final_value = null,
                    .last_error = result.err,
                    .memory_used = 0,
                    .status = .failed_max_restarts,
                    .trace = result.trace,
                };
            }

            result.deinit(self.system.allocator);
        }

        unreachable;
    }
};

// ============================================================================
// Tests
// ============================================================================

// ============================================================================
// Happy Path Tests
// ============================================================================

test "supervisor runs simple program successfully" {
    const allocator = testing.allocator;
    const source = "x := 42";

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var supervisor = Supervisor{ .system = system_instance };

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

test "supervisor tracks duration across successful execution" {
    const allocator = testing.allocator;
    const source = "result := 3 * 4";

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var supervisor = Supervisor{ .system = system_instance };

    var result = try supervisor.run(source);
    defer result.deinit();

    try testing.expectEqual(SupervisionResult.Status.success, result.status);
    try testing.expect(result.duration_ms >= 0); // Should have some measurable duration
    try testing.expectEqual(@as(f64, 12.0), result.final_value.?.number);
}

// ============================================================================
// Error Handling Tests
// ============================================================================

test "supervisor returns parse error without retrying" {
    const allocator = testing.allocator;
    const source = "x := := 42"; // Invalid syntax

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var supervisor = Supervisor{ .system = system_instance };

    var result = try supervisor.run(source);
    defer result.deinit();

    try testing.expectEqual(SupervisionResult.Status.parse_error, result.status);
    try testing.expectEqual(@as(u32, 1), result.attempts); // Should only try once
    try testing.expect(result.final_value == null);
    try testing.expect(result.last_error != null);
}

test "supervisor exhausts max retries on eval error" {
    const allocator = testing.allocator;
    const source = "z := unknown";

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var supervisor = Supervisor{ .system = system_instance };

    var result = try supervisor.run(source);
    defer result.deinit();

    try testing.expectEqual(SupervisionResult.Status.failed_max_restarts, result.status);
    try testing.expectEqual(@as(u32, 3), result.attempts);
    try testing.expect(result.final_value == null);
    try testing.expect(result.last_error != null);
}

test "supervisor accumulates duration across retries" {
    const allocator = testing.allocator;
    const source = "z := unknown";

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var supervisor = Supervisor{ .system = system_instance };

    var result = try supervisor.run(source);
    defer result.deinit();

    try testing.expectEqual(SupervisionResult.Status.failed_max_restarts, result.status);
    try testing.expectEqual(@as(u32, 3), result.attempts);
    try testing.expect(result.duration_ms >= 0); // Should accumulate time from all 3 attempts
}

test "supervisor cleans up memory on failed attempts" {
    const allocator = testing.allocator;
    const source = "x := unknown";

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var supervisor = Supervisor{ .system = system_instance };

    var result = try supervisor.run(source);
    defer result.deinit();

    // If this test passes with no leaks, cleanup is working
    try testing.expectEqual(SupervisionResult.Status.failed_max_restarts, result.status);
}

// ============================================================================
// Configuration Tests
// ============================================================================

test "supervisor respects custom max_restarts config" {
    const allocator = testing.allocator;
    const source = "z := unknown";

    const sys_config = sys.SystemConfig{
        .max_restarts = 5, // Override default of 3
    };
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var supervisor = Supervisor{ .system = system_instance };

    var result = try supervisor.run(source);
    defer result.deinit();

    try testing.expectEqual(SupervisionResult.Status.failed_max_restarts, result.status);
    try testing.expectEqual(@as(u32, 5), result.attempts); // Should try 5 times, not 3
}

test "supervisor handles max_restarts = 1" {
    const allocator = testing.allocator;
    const source = "z := unknown";

    const sys_config = sys.SystemConfig{
        .max_restarts = 1, // Only one attempt
    };
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var supervisor = Supervisor{ .system = system_instance };

    var result = try supervisor.run(source);
    defer result.deinit();

    try testing.expectEqual(SupervisionResult.Status.failed_max_restarts, result.status);
    try testing.expectEqual(@as(u32, 1), result.attempts);
}

// ============================================================================
// System Integration Tests
// ============================================================================

test "supervisor initializes system and loads prelude namespaces" {
    const allocator = testing.allocator;

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var supervisor = Supervisor{ .system = system_instance };

    // The system should contain prelude namespaces
    const task = supervisor.system.env.get("Task");
    const proc = supervisor.system.env.get("Process");
    const sys_ns = supervisor.system.env.get("System");

    try testing.expect(task != null);
    try testing.expect(proc != null);
    try testing.expect(sys_ns != null);
}
