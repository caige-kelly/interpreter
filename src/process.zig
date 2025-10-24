const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Value = @import("evaluator.zig").Value;
const Result = @import("evaluator.zig").Result;
const ast = @import("ast.zig");
const eval = @import("evaluator.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const sys = @import("system.zig");

pub const TraceEntry = eval.TraceEntry;

// ============================================================================
// RunAttempt
// ============================================================================
pub const RunAttempt = struct {
    status: Status,
    value: ?eval.Value,
    err_msg: ?[]const u8,
    trace: ?[]const TraceEntry,
    duration_ms: u64,
    memory_used: usize,

    pub const Status = enum {
        success,
        eval_error,
        parse_error,
        timeout,
    };

    pub fn deinit(self: *RunAttempt, allocator: Allocator) void {
        if (self.trace) |t| allocator.free(t);

        // Clean up the value if it exists
        if (self.value) |val| {
            freeValue(allocator, val);
        }

        // Clean up err_msg if it exists (for error cases where value is null)
        if (self.err_msg) |msg| {
            allocator.free(msg);
        }
    }

    pub fn freeValue(allocator: Allocator, value: Value) void {
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

                // Note: r.meta.deinit() might do nothing or might have its own cleanup
                // Check what Meta.deinit() actually does
                r.meta.deinit();

                // Finally destroy the Result struct itself
                allocator.destroy(r);
            },
            else => {},
        }
    }
};

// ============================================================================
// Process
// ============================================================================
pub const Process = struct {
    allocator: Allocator,
    enable_trace: bool = true,

    pub fn executeOnce(self: *Process, source: []const u8) !RunAttempt {
        const start_time = try std.time.Instant.now();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // 1. Tokenize
        const tokens = lexer.tokenize(source, arena.allocator()) catch {
            return makeAttempt(.parse_error, null, null, null, start_time);
        };

        // 2. Parse
        const program = parser.parse(tokens, arena.allocator()) catch {
            return makeAttempt(.parse_error, null, null, null, start_time);
        };

        // 3. Evaluate
        const eval_config = eval.EvalConfig{ .enable_trace = self.enable_trace };
        const value = eval.evaluate(program, arena.allocator(), eval_config) catch {
            return makeAttempt(.eval_error, null, null, null, start_time);
        };

        // 4. Trace stub
        const trace_copy = if (self.enable_trace) blk: {
            const copy = try self.allocator.alloc(TraceEntry, 0);
            break :blk copy;
        } else null;

        const end_time = try std.time.Instant.now();
        const duration_ms = end_time.since(start_time) / std.time.ns_per_ms;

        // CRITICAL: Copy the value BEFORE arena deinit
        const value_copy = try copyValue(self.allocator, value);

        // Check if the value is an error Result
        const is_error = switch (value_copy) {
            .result => |r| r.isErr(),
            else => false,
        };

        if (is_error) {
            // Extract err_msg before freeing
            const err_msg_copy = switch (value_copy) {
                .result => |r| if (r.err_msg) |msg| try self.allocator.dupe(u8, msg) else null,
                else => null,
            };

            // Free the value copy since we won't be using it
            freeValue(self.allocator, value_copy);

            return RunAttempt{
                .status = .eval_error,
                .value = null,
                .err_msg = err_msg_copy,
                .trace = trace_copy,
                .duration_ms = duration_ms,
                .memory_used = 0,
            };
        } else {
            return RunAttempt{
                .status = .success,
                .value = value_copy,
                .err_msg = null,
                .trace = trace_copy,
                .duration_ms = duration_ms,
                .memory_used = 0,
            };
        }
    }

    // Make freeValue public or a standalone function
    pub fn freeValue(allocator: Allocator, value: Value) void {
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

                // Deinit meta (if needed)
                r.meta.deinit();

                // Finally destroy the Result struct itself
                allocator.destroy(r);
            },
            else => {},
        }
    }

    // Deep copy a Value (including Result pointers) to a new allocator
    fn copyValue(allocator: Allocator, value: Value) !Value {
        return switch (value) {
            .number => |n| Value{ .number = n },
            .string => |s| Value{ .string = try allocator.dupe(u8, s) },
            .boolean => |b| Value{ .boolean = b },
            .none => Value{ .none = {} },
            .result => |r| blk: {
                const result_copy = try allocator.create(eval.Result);

                // Deep copy the value inside the result
                const value_copy = if (r.value) |v| try copyValueInner(allocator, v) else null;

                // Copy error message
                const err_copy = if (r.err_msg) |msg| try allocator.dupe(u8, msg) else null;

                // Copy expr_source string
                const expr_source_copy = try allocator.dupe(u8, r.meta.expr_source);

                result_copy.* = .{
                    .value = value_copy,
                    .err_msg = err_copy,
                    .meta = eval.Meta.init(expr_source_copy, allocator),
                };
                result_copy.meta.duration_ns = r.meta.duration_ns;

                break :blk Value{ .result = result_copy };
            },
        };
    }

    // Helper to copy Value without hitting .result recursion
    fn copyValueInner(allocator: Allocator, value: Value) !Value {
        return switch (value) {
            .number => |n| Value{ .number = n },
            .string => |s| Value{ .string = try allocator.dupe(u8, s) },
            .boolean => |b| Value{ .boolean = b },
            .none => Value{ .none = {} },
            .result => unreachable, // Should not have nested results yet
        };
    }
};

// ============================================================================
// Internal Helper
// ============================================================================
fn makeAttempt(
    status: RunAttempt.Status,
    value: ?eval.Value,
    err_msg: ?[]const u8,
    trace: ?[]const TraceEntry,
    start_time: std.time.Instant,
) RunAttempt {
    const end_time = std.time.Instant.now() catch |e| {
        std.debug.print("Instant.now() failed: {s}\n", .{@errorName(e)});
        return makeAttempt(status, value, err_msg, trace, start_time);
    };

    const duration_ms = end_time.since(start_time) / std.time.ns_per_ms;
    return RunAttempt{
        .status = status,
        .value = value,
        .err_msg = err_msg,
        .trace = trace,
        .duration_ms = duration_ms,
        .memory_used = 0,
    };
}

// ============================================================================
// Tests
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
    try testing.expect(attempt.err_msg == null);
    try testing.expect(attempt.trace != null);
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
    try testing.expect(attempt.duration_ms >= 0);
    // Result of assignment is unwrapped value
    try testing.expect(attempt.value != null);
    try testing.expectEqual(@as(f64, 10.0), attempt.value.?.number);
}

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
    try testing.expect(attempt.err_msg != null);
}
