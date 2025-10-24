const std = @import("std");
const Ast = @import("ast.zig");
const TokenType = @import("token.zig").TokenType;

pub const EvalError = error{
    OutOfMemory,
    InternalFault,
};

// Add this near the top with your other type definitions
pub const Environment = struct {
    bindings: std.StringHashMap(Value),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Environment {
        return Environment{
            .bindings = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Environment) void {
        // Free all stored values
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            // Free the key (variable name was duplicated)
            self.allocator.free(entry.key_ptr.*);
            // Free the value if it contains allocated memory
            freeValue(self.allocator, entry.value_ptr.*);
        }
        self.bindings.deinit();
    }

    pub fn set(self: *Environment, name: []const u8, value: Value) !void {
        // Deep copy the value so it persists after arena cleanup
        const value_copy = try self.copyValue(value);

        // Check if variable already exists
        if (self.bindings.get(name)) |old_value| {
            // Free the old value
            freeValue(self.allocator, old_value);
            // Remove old key
            var iter = self.bindings.iterator();
            while (iter.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                    self.allocator.free(entry.key_ptr.*);
                    break;
                }
            }
        }

        // Duplicate the name so it persists
        const name_copy = try self.allocator.dupe(u8, name);
        try self.bindings.put(name_copy, value_copy);
    }

    fn copyValue(self: *Environment, value: Value) !Value {
        return switch (value) {
            .number => |n| Value{ .number = n },
            .boolean => |b| Value{ .boolean = b },
            .none => Value{ .none = {} },
            .string => |s| Value{ .string = try self.allocator.dupe(u8, s) },
            .result => |r| {
                const result_copy = try self.allocator.create(Result);

                const value_copy = if (r.value) |v| try self.copyValue(v) else null;
                const err_copy = if (r.err_msg) |msg| try self.allocator.dupe(u8, msg) else null;
                const expr_source_copy = try self.allocator.dupe(u8, r.meta.expr_source);

                result_copy.* = .{
                    .value = value_copy,
                    .err_msg = err_copy,
                    .meta = Meta.init(expr_source_copy, self.allocator),
                };
                result_copy.meta.duration_ns = r.meta.duration_ns;

                return Value{ .result = result_copy };
            },
        };
    }

    pub fn get(self: *Environment, name: []const u8) ?Value {
        return self.bindings.get(name);
    }

    fn freeValue(allocator: std.mem.Allocator, value: Value) void {
        switch (value) {
            .string => |s| allocator.free(s),
            .result => |r| {
                if (r.value) |*v| {
                    freeValue(allocator, v.*);
                }
                if (r.err_msg) |msg| {
                    allocator.free(msg);
                }
                if (r.meta.expr_source.len > 0) {
                    allocator.free(r.meta.expr_source);
                }
                r.meta.deinit();
                allocator.destroy(r);
            },
            else => {},
        }
    }
};

// ============================================================================
// Core Types
// ============================================================================

/// Result = ok(Value) or err(message), always with metadata
pub const Result = struct {
    value: ?Value,
    err_msg: ?[]const u8,
    meta: Meta,

    pub fn ok(val: Value, meta: Meta) Result {
        return .{ .value = val, .err_msg = null, .meta = meta };
    }

    pub fn err(msg: []const u8, meta: Meta) Result {
        return .{ .value = null, .err_msg = msg, .meta = meta };
    }

    pub fn isOk(self: Result) bool {
        return self.value != null;
    }

    pub fn isErr(self: Result) bool {
        return self.err_msg != null;
    }

    pub fn print(self: *const Result, writer: anytype) !void {
        if (self.value) |val| {
            try writer.writeAll("ok(");
            try val.print(writer);
            try writer.print(", {s})", .{@tagName(val)});
        } else if (self.err_msg) |msg| {
            try writer.print("err(\"{s}\")", .{msg});
        }
    }
};

/// Metadata attached to results
pub const Meta = struct {
    expr_source: []const u8,
    duration_ns: u64,
    extra: std.StringHashMap([]const u8),

    pub fn init(expr_source: []const u8, allocator: std.mem.Allocator) Meta {
        return .{
            .expr_source = expr_source,
            .duration_ns = 0,
            .extra = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn withDuration(self: Meta, ns: u64) Meta {
        var m = self;
        m.duration_ns = ns;
        return m;
    }

    pub fn deinit(self: *Meta) void {
        self.extra.deinit();
    }
};

/// Value = the data types in Ripple (including Result as a first-class type)
pub const Value = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    none: void,
    result: *Result, // Result is a value!

    pub fn print(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .number => |n| try writer.print("{d}", .{n}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .boolean => |b| try writer.print("{}", .{b}),
            .none => try writer.print("none", .{}),
            .result => |r| {
                if (r.isOk()) {
                    if (r.value) |val| {
                        try writer.print("Ok(", .{});
                        try val.print(writer); // This is safe - only IO errors can happen
                        try writer.print(")", .{});
                    } else {
                        try writer.print("Ok(none)", .{});
                    }
                } else {
                    if (r.err_msg) |msg| {
                        try writer.print("Err(\"{s}\")", .{msg});
                    } else {
                        try writer.print("Err(unknown)", .{});
                    }
                }
            },
        }
    }
};

pub const TraceEntry = struct {
    expr_source: []const u8,
    value: Value,
    timestamp_ms: i64,
    duration_ns: u64,
};

pub const EvaluationResult = struct {
    value: Value,
    trace: []TraceEntry,
};

// ============================================================================
// Evaluator
// ============================================================================

pub const EvalConfig = struct {
    enable_trace: bool = false,
};

const EvalState = struct {
    globals: *Environment, // Changed from StringHashMap(Value) to *Environment
    allocator: std.mem.Allocator,
};

pub fn evaluate(
    program: Ast.Program,
    allocator: std.mem.Allocator,
    config: EvalConfig,
    env: ?*Environment,
) EvalError!Value {
    _ = config;

    var temp_env = if (env == null) try Environment.init(allocator) else null;
    defer if (temp_env) |*e| e.deinit();

    const active_env = env orelse &temp_env.?;

    var state = EvalState{
        .globals = active_env, // Use the environment instead of a new hashmap
        .allocator = allocator,
    };

    var last_value = Value{ .none = {} };

    for (program.expressions) |expr| {
        const start = std.time.nanoTimestamp();
        last_value = try evalExpr(&state, expr);
        _ = start;
    }

    return last_value;
}

// ============================================================================
// Expression Evaluation
// ============================================================================

fn evalExpr(state: *EvalState, expr: Ast.Expr) EvalError!Value {
    return switch (expr) {
        .literal => |lit| try evalLiteral(state, lit),
        .assignment => |asgn| try evalAssignment(state, asgn),
        .binary => |bin| try evalBinary(state, bin),
        .identifier => |id| try evalIdentifier(state, id),
        else => Value{ .none = {} },
    };
}

// "5" evaluates to Value{ .result = ok(5, meta) }
fn evalLiteral(state: *EvalState, lit: Ast.Literal) EvalError!Value {
    const inner_value = switch (lit) {
        .string => |s| Value{ .string = s },
        .number => |n| Value{ .number = n },
        .boolean => |b| Value{ .boolean = b },
        .none => Value{ .none = {} },
    };

    const result_ptr = try state.allocator.create(Result);
    result_ptr.* = Result.ok(inner_value, Meta.init("literal", state.allocator));

    return Value{ .result = result_ptr };
}

fn evalIdentifier(state: *EvalState, name: []const u8) EvalError!Value {
    if (state.globals.get(name)) |val| { // Now calls Environment.get()
        return val;
    }

    // Return an error Result
    const result_ptr = try state.allocator.create(Result);
    result_ptr.* = Result.err("undefined variable", Meta.init("identifier", state.allocator));
    return Value{ .result = result_ptr };
}

fn evalAssignment(state: *EvalState, assign: Ast.AssignExpr) EvalError!Value {
    if (state.globals.bindings.contains(assign.name)) { // Check if exists
        const result_ptr = try state.allocator.create(Result);
        result_ptr.* = Result.err("variable already defined", Meta.init("assignment", state.allocator));
        return Value{ .result = result_ptr };
    }

    // Evaluate RHS
    const rhs_value = try evalExpr(state, assign.value.*);

    // Unwrap if it's a Result
    const unwrapped_value = switch (rhs_value) {
        .result => |r| blk: {
            if (r.isErr()) {
                // Propagate error
                return rhs_value;
            }
            // Unwrap the ok value
            break :blk r.value.?;
        },
        else => rhs_value, // Already unwrapped
    };

    // Store unwrapped value using Environment.set()
    try state.globals.set(assign.name, unwrapped_value);

    // Return unwrapped value
    return unwrapped_value;
}

// In evaluator.zig, update evalBinary:

fn evalBinary(state: *EvalState, bin: Ast.BinaryExpr) EvalError!Value {
    const left_value = try evalExpr(state, bin.left.*);
    const right_value = try evalExpr(state, bin.right.*);

    // Auto-unwrap if they're Results and clean up the wrapper
    const left = switch (left_value) {
        .result => |r| blk: {
            if (r.isErr()) return left_value;
            const val = r.value.?;
            // Clean up the Result wrapper's meta
            var meta = r.meta;
            meta.deinit();
            state.allocator.destroy(r);
            break :blk val;
        },
        else => left_value,
    };

    const right = switch (right_value) {
        .result => |r| blk: {
            if (r.isErr()) return right_value;
            const val = r.value.?;
            // Clean up the Result wrapper's meta
            var meta = r.meta;
            meta.deinit();
            state.allocator.destroy(r);
            break :blk val;
        },
        else => right_value,
    };

    // Type check
    if (left != .number or right != .number) {
        const result_ptr = try state.allocator.create(Result);
        result_ptr.* = Result.err("type mismatch: expected numbers", Meta.init("binary", state.allocator));
        return Value{ .result = result_ptr };
    }

    // Division by zero check
    if (bin.operator == .SLASH and right.number == 0) {
        const result_ptr = try state.allocator.create(Result);
        result_ptr.* = Result.err("division by zero", Meta.init("binary", state.allocator));
        return Value{ .result = result_ptr };
    }

    // Compute result
    const result_number = switch (bin.operator) {
        .PLUS => left.number + right.number,
        .MINUS => left.number - right.number,
        .STAR => left.number * right.number,
        .SLASH => left.number / right.number,
        else => 0.0,
    };

    // Wrap in Result
    const result_ptr = try state.allocator.create(Result);
    result_ptr.* = Result.ok(Value{ .number = result_number }, Meta.init("binary", state.allocator));

    return Value{ .result = result_ptr };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "5 evaluates to Value{ .result = ok(5) }" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("5", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null); // Add null

    try testing.expect(value == .result);
    try testing.expect(value.result.isOk());
    try testing.expect(value.result.value.? == .number);
    try testing.expectEqual(@as(f64, 5.0), value.result.value.?.number);
}

test "x := 5 evaluates to Value{ .number = 5 }" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := 5", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null); // Add null

    try testing.expect(value == .number);
    try testing.expectEqual(@as(f64, 5.0), value.number);
}
