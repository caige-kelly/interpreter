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
// Temporary stub (until full trace and supervision logging are re-enabled)
// ============================================================================
pub const TraceEntry = eval.TraceEntry;

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
    last_error: ?[]const u8,
    allocator: Allocator,

    pub const Status = enum {
        success,
        failed_max_restarts,
        eval_error,
        parse_error,
        timeout,
    };

    pub fn deinit(self: *SupervisionResult) void {
        if (self.trace) |t| self.allocator.free(t);

        // Clean up the final_value if it exists
        if (self.final_value) |val| {
            freeValue(self.allocator, val);
        }

        // Clean up last_error if it exists
        if (self.last_error) |err| {
            self.allocator.free(err);
        }
    }

    fn freeValue(allocator: Allocator, value: eval.Value) void {
        switch (value) {
            .string => |s| allocator.free(s),
            .result => |r| {
                // Free inner value first
                if (r.value) |*v| {
                    freeValue(allocator, v.*);
                }

                // Free error message
                if (r.err_msg) |msg| {
                    allocator.free(msg);
                }

                // Free expr_source
                if (r.meta.expr_source.len > 0) {
                    allocator.free(r.meta.expr_source);
                }

                // Deinit meta
                r.meta.deinit();

                // Finally destroy the Result struct itself
                allocator.destroy(r);
            },
            else => {},
        }
    }
};

// ============================================================================
// Supervisor
// ============================================================================
pub const Supervisor = struct {
    system: sys.System,

    pub fn run(self: *Supervisor, source: []const u8) !SupervisionResult {
        var process = try self.system.spawnProcess("main");

        var total_duration: u64 = 0;
        var attempt: u32 = 1;

        while (attempt <= self.system.config.max_restarts) : (attempt += 1) {
            var result = try process.executeOnce(source);
            total_duration += result.duration_ms;

            // In supervisor.zig, in the run() function:

            switch (result.status) {
                .success => {
                    // Transfer ownership of value and trace
                    const final_value = result.value;
                    const trace = result.trace;

                    // Clear these so deinit doesn't free them
                    result.value = null;
                    result.trace = null;

                    // Clean up everything else
                    result.deinit(self.system.allocator);

                    return SupervisionResult{
                        .allocator = self.system.allocator,
                        .attempts = attempt,
                        .duration_ms = total_duration,
                        .final_value = final_value,
                        .last_error = null,
                        .memory_used = 0,
                        .status = .success,
                        .trace = trace,
                    };
                },
                .parse_error => {
                    // Copy error message before cleaning up
                    const last_error_copy = if (result.err_msg) |msg|
                        try self.system.allocator.dupe(u8, msg)
                    else
                        null;

                    result.deinit(self.system.allocator);

                    return SupervisionResult{
                        .allocator = self.system.allocator,
                        .attempts = attempt,
                        .duration_ms = total_duration,
                        .final_value = null,
                        .last_error = last_error_copy,
                        .memory_used = 0,
                        .status = .parse_error,
                        .trace = null,
                    };
                },
                .eval_error => {
                    if (attempt == self.system.config.max_restarts) {
                        // Copy error message before cleaning up
                        const last_error_copy = if (result.err_msg) |msg|
                            try self.system.allocator.dupe(u8, msg)
                        else
                            null;

                        result.deinit(self.system.allocator);

                        return SupervisionResult{
                            .allocator = self.system.allocator,
                            .attempts = attempt,
                            .duration_ms = total_duration,
                            .final_value = null,
                            .last_error = last_error_copy,
                            .memory_used = 0,
                            .status = .failed_max_restarts,
                            .trace = null,
                        };
                    }
                },
                else => {},
            }

            // clean up after each failed run
            result.deinit(self.system.allocator);
        }

        unreachable;
    }
};

// ============================================================================
// Tests
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
}

test "supervisor evaluates binary operation to wrapped Result" {
    const allocator = testing.allocator;
    const source = "3 * 4"; // No assignment - returns wrapped Result

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var supervisor = Supervisor{ .system = system_instance };
    var result = try supervisor.run(source);
    defer result.deinit();

    try testing.expectEqual(SupervisionResult.Status.success, result.status);
    // Binary operation returns wrapped Result
    try testing.expect(result.final_value != null);
    try testing.expect(result.final_value.? == .result);
    try testing.expect(result.final_value.?.result.isOk());
    try testing.expectEqual(@as(f64, 12.0), result.final_value.?.result.value.?.number);
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
    try testing.expect(result.duration_ms >= 0);
    // Assignment returns unwrapped value
    try testing.expect(result.final_value != null);
    try testing.expect(result.final_value.? == .number);
    try testing.expectEqual(@as(f64, 12.0), result.final_value.?.number);
}

test "supervisor returns parse error without retrying" {
    const allocator = testing.allocator;
    const source = "x := := 42";

    const sys_config = sys.SystemConfig{};
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var supervisor = Supervisor{ .system = system_instance };
    var result = try supervisor.run(source);
    defer result.deinit();

    try testing.expectEqual(SupervisionResult.Status.parse_error, result.status);
    try testing.expectEqual(@as(u32, 1), result.attempts);
    try testing.expect(result.final_value == null);
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
    try testing.expect(result.final_value == null);
}

test "supervisor respects custom max_restarts config" {
    const allocator = testing.allocator;
    const source = "z := unknown";

    const sys_config = sys.SystemConfig{ .max_restarts = 2 };
    var system_instance = try sys.System.init(allocator, sys_config);
    defer system_instance.deinit();

    var supervisor = Supervisor{ .system = system_instance };
    var result = try supervisor.run(source);
    defer result.deinit();

    try testing.expectEqual(SupervisionResult.Status.failed_max_restarts, result.status);
    try testing.expectEqual(@as(u32, 2), result.attempts);
}
