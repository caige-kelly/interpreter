const std = @import("std");
const Ast = @import("ast.zig");
const TokenType = @import("token.zig").TokenType;

pub const EvalError = error{
    OutOfMemory,
    InternalFault,
};

// ============================================================================
// Environment
// ============================================================================

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
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeValue(self.allocator, entry.value_ptr.*); // ← Fixed parameter order
        }
        self.bindings.deinit();
    }

    pub fn set(self: *Environment, name: []const u8, value: Value) !void {
        const value_copy = try self.copyValue(value);

        // If key exists, get and free it
        if (self.bindings.fetchRemove(name)) |old_entry| {
            self.allocator.free(old_entry.key);
            freeValue(self.allocator, old_entry.value); // ← Fixed parameter order
        }

        const name_copy = try self.allocator.dupe(u8, name);
        try self.bindings.put(name_copy, value_copy);
    }

    pub fn get(self: *Environment, name: []const u8) ?Value {
        return self.bindings.get(name);
    }

    fn copyValue(self: *Environment, value: Value) !Value {
        return switch (value) {
            .number => |n| Value{ .number = n },
            .boolean => |b| Value{ .boolean = b },
            .none => Value{ .none = {} },
            .string => |s| Value{ .string = try self.allocator.dupe(u8, s) },
            .result => |r| {
                const result_copy = try self.allocator.create(Result);
                result_copy.* = switch (r.*) {
                    .ok => |ok| blk: {
                        const value_copy = try self.copyValue(ok.value);
                        break :blk Result{ .ok = .{ .value = value_copy } };
                    },
                    .err => |err| Result{
                        .err = .{ .error_msg = try self.allocator.dupe(u8, err.error_msg) },
                    },
                };
                return Value{ .result = result_copy };
            },
        };
    }

    pub fn freeValue(allocator: std.mem.Allocator, value: Value) void {
        switch (value) {
            .string => |s| {
                allocator.free(s);
            },
            .result => |r| {
                if (r.isOk()) {
                    // Recursively free the ok value
                    freeValue(allocator, r.ok.value);
                } else {
                    // Free error message string
                    if (r.err.error_msg.len > 0) {
                        allocator.free(r.err.error_msg);
                    }
                }
                // Free the Result pointer itself
                allocator.destroy(r);
            },
            // .list => |l| {
            //     for (l.items) |item| {
            //         freeValue(allocator, item);
            //     }
            //     allocator.free(l.items);
            // },
            // These types don't own heap memory
            .number, .boolean, .none => {},
        }
    }
};

// ============================================================================
// Core Types
// ============================================================================

pub const Result = union(enum) {
    ok: struct { value: Value },
    err: struct { error_msg: []const u8 },

    pub fn isOk(self: *const Result) bool {
        return self.* == .ok;
    }

    pub fn isErr(self: *const Result) bool {
        return self.* == .err;
    }
};

pub const Value = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    none: void,
    result: *Result,

    pub fn print(self: Value, writer: anytype) !void {
        switch (self) {
            .number => |n| try writer.print("{d}", .{n}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .boolean => |b| try writer.print("{}", .{b}),
            .none => try writer.print("none", .{}),
            .result => |r| {
                switch (r.*) {
                    .ok => |ok| {
                        try writer.writeAll("ok(");
                        try ok.value.print(writer);
                        try writer.writeAll(")");
                    },
                    .err => |err| {
                        try writer.print("err(\"{s}\")", .{err.error_msg});
                    },
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

// ============================================================================
// Evaluator
// ============================================================================

pub const EvalConfig = struct {
    enable_trace: bool = false,
};

const EvalState = struct {
    globals: *Environment,
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
        .globals = active_env,
        .allocator = allocator,
    };

    var last_value = Value{ .none = {} };
    for (program.expressions) |expr| {
        last_value = try evalExpr(&state, expr);
    }

    return last_value;
}

fn evalExpr(state: *EvalState, expr: Ast.Expr) EvalError!Value {
    return switch (expr) {
        .literal => |lit| evalLiteral(state, lit),
        .identifier => |id| evalIdentifier(state, id),
        .assignment => |asgn| evalAssignment(state, asgn),
        .binary => |bin| evalBinary(state, bin),
        .ok_expr => |ok_e| evalOk(state, ok_e),
        .err_expr => |err_e| evalErr(state, err_e),
        else => Value{ .none = {} },
    };
}

fn evalLiteral(state: *EvalState, lit: Ast.Literal) EvalError!Value {
    return switch (lit) {
        .number => |n| Value{ .number = n },
        .string => |s| Value{ .string = try state.allocator.dupe(u8, s) },
        .boolean => |b| Value{ .boolean = b },
        .none => Value{ .none = {} },
    };
}

fn evalIdentifier(state: *EvalState, name: []const u8) EvalError!Value {
    if (state.globals.get(name)) |val| return val;
    return try createErrorResult(state, "undefined variable");
}

fn evalAssignment(state: *EvalState, assign: Ast.AssignExpr) EvalError!Value {
    // Allow reassignment (like Python/Rust with mut)
    const rhs_value = try evalExpr(state, assign.value.*);
    try state.globals.set(assign.name, rhs_value);
    return rhs_value;
}

fn evalBinary(state: *EvalState, bin: Ast.BinaryExpr) EvalError!Value {
    const left_value = try evalExpr(state, bin.left.*);
    const right_value = try evalExpr(state, bin.right.*);

    // Track whether we need to clean up wrapped values
    const left_was_result = (left_value == .result);
    const right_was_result = (right_value == .result);

    // Unwrap both sides
    const left = try unwrapValue(left_value);
    const right = try unwrapValue(right_value);

    // If unwrapping resulted in an error, propagate it
    if (left == .result) {
        if (right != .result) {
            cleanupValue(state.allocator, right);
        }
        if (right_was_result) {
            cleanupValue(state.allocator, right_value);
        }
        return left;
    }
    if (right == .result) {
        cleanupValue(state.allocator, left);
        if (left_was_result) {
            cleanupValue(state.allocator, left_value);
        }
        return right;
    }

    // Type check
    if (left != .number or right != .number) {
        cleanupValue(state.allocator, left);
        cleanupValue(state.allocator, right);
        if (left_was_result) cleanupValue(state.allocator, left_value);
        if (right_was_result) cleanupValue(state.allocator, right_value);
        return try createErrorResult(state, "type mismatch: expected numbers");
    }

    const result = switch (bin.operator) {
        .PLUS => left.number + right.number,
        .MINUS => left.number - right.number,
        .STAR => left.number * right.number,
        .SLASH => blk: {
            if (right.number == 0) {
                cleanupValue(state.allocator, left);
                cleanupValue(state.allocator, right);
                if (left_was_result) cleanupValue(state.allocator, left_value);
                if (right_was_result) cleanupValue(state.allocator, right_value);
                return try createErrorResult(state, "division by zero");
            }
            break :blk left.number / right.number;
        },
        else => {
            cleanupValue(state.allocator, left);
            cleanupValue(state.allocator, right);
            if (left_was_result) cleanupValue(state.allocator, left_value);
            if (right_was_result) cleanupValue(state.allocator, right_value);
            return try createErrorResult(state, "unknown operator");
        },
    };

    // Clean up intermediate values
    cleanupValue(state.allocator, left);
    cleanupValue(state.allocator, right);
    if (left_was_result) cleanupValue(state.allocator, left_value);
    if (right_was_result) cleanupValue(state.allocator, right_value);

    return Value{ .number = result };
}

fn evalOk(state: *EvalState, ok_expr: Ast.OkExpr) EvalError!Value {
    const value = try evalExpr(state, ok_expr.value.*);

    // Create Result pointer
    const result_ptr = try state.allocator.create(Result);
    result_ptr.* = Result{
        .ok = .{ .value = value },
    };

    return Value{ .result = result_ptr };
}

fn evalErr(state: *EvalState, err_expr: Ast.ErrExpr) EvalError!Value {
    const message_value = try evalExpr(state, err_expr.message.*);
    defer cleanupValue(state.allocator, message_value);

    // Extract string from the value
    const error_msg = switch (message_value) {
        .string => |s| try state.allocator.dupe(u8, s),
        .result => |r| blk: {
            if (r.isOk()) {
                const inner = r.ok.value;
                if (inner == .string) {
                    break :blk try state.allocator.dupe(u8, inner.string);
                } else {
                    break :blk try state.allocator.dupe(u8, "err() requires string argument");
                }
            } else {
                break :blk try state.allocator.dupe(u8, r.err.error_msg);
            }
        },
        else => try state.allocator.dupe(u8, "err() requires string argument"),
    };

    // Create Result pointer
    const result_ptr = try state.allocator.create(Result);
    result_ptr.* = Result{
        .err = .{ .error_msg = error_msg },
    };

    return Value{ .result = result_ptr };
}

fn unwrapValue(value: Value) EvalError!Value {
    return switch (value) {
        .result => |r| switch (r.*) {
            .ok => |ok| ok.value,
            .err => value, // Propagate error
        },
        else => value,
    };
}

fn createErrorResult(state: *EvalState, msg: []const u8) EvalError!Value {
    const result_ptr = try state.allocator.create(Result);
    result_ptr.* = Result{
        .err = .{ .error_msg = try state.allocator.dupe(u8, msg) },
    };
    return Value{ .result = result_ptr };
}

pub fn cleanupValue(allocator: std.mem.Allocator, value: Value) void {
    Environment.freeValue(allocator, value);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "evaluate number literal" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("42", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expectEqual(@as(f64, 42.0), value.number);
}

test "evaluate string literal" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("\"hello\"", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expectEqualStrings("hello", value.string);
}

test "evaluate boolean literal" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("true", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    // Debug: print the tokens
    std.debug.print("\nTokens: ", .{});
    for (tokens) |token| {
        std.debug.print("{any} ", .{token.type});
    }
    std.debug.print("\n", .{});

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    // Debug: print the AST
    std.debug.print("AST: {any}\n", .{program.expressions[0]});

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    // Debug: print the value
    std.debug.print("Value: {any}\n", .{value});

    try testing.expectEqual(true, value.boolean);
}

test "evaluate addition" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("2 + 3", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expectEqual(@as(f64, 5.0), value.number);
}

test "evaluate subtraction" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("10 - 3", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expectEqual(@as(f64, 7.0), value.number);
}

test "evaluate multiplication" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("4 * 5", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expectEqual(@as(f64, 20.0), value.number);
}

test "evaluate division" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("15 / 3", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expectEqual(@as(f64, 5.0), value.number);
}

test "ok() wraps values" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("ok(5)", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expect(value == .result);
    try testing.expect(value.result.isOk());
    try testing.expectEqual(@as(f64, 5.0), value.result.ok.value.number);
}

test "ok() can wrap strings" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("ok(\"hello\")", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expect(value == .result);
    try testing.expect(value.result.isOk());
    try testing.expectEqualStrings("hello", value.result.ok.value.string);
}

test "ok() can wrap Results (nested)" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("ok(ok(42))", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expect(value == .result);
    try testing.expect(value.result.isOk());
    try testing.expect(value.result.ok.value == .result);
    try testing.expect(value.result.ok.value.result.isOk());
    try testing.expectEqual(@as(f64, 42.0), value.result.ok.value.result.ok.value.number);
}

test "err() creates error Result" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("err(\"failed\")", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expect(value == .result);
    try testing.expect(value.result.isErr());
    try testing.expectEqualStrings("failed", value.result.err.error_msg);
}

test "err() with non-string returns error" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("err(42)", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expect(value == .result);
    try testing.expect(value.result.isErr());
    try testing.expect(std.mem.indexOf(u8, value.result.err.error_msg, "requires string") != null);
}

test "err() with ok(string) unwraps correctly" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("err(ok(\"wrapped\"))", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expect(value == .result);
    try testing.expect(value.result.isErr());
    try testing.expectEqualStrings("wrapped", value.result.err.error_msg);
}

// Assignment with Results
test "assigning ok() stores Result type" {
    const allocator = testing.allocator;

    var env = try Environment.init(allocator);
    defer env.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := ok(99)", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const result = try evaluate(program, allocator, .{}, &env);
    defer cleanupValue(allocator, result);

    const stored = env.get("x").?;
    try testing.expect(stored == .result);
    try testing.expect(stored.result.isOk());
    try testing.expectEqual(@as(f64, 99.0), stored.result.ok.value.number);
}

test "assigning err() stores error Result" {
    const allocator = testing.allocator;

    var env = try Environment.init(allocator);
    defer env.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := err(\"test\")", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const result = try evaluate(program, allocator, .{}, &env);
    defer cleanupValue(allocator, result);

    const stored = env.get("x").?;
    try testing.expect(stored == .result);
    try testing.expect(stored.result.isErr());
    try testing.expectEqualStrings("test", stored.result.err.error_msg);
}

// Complex expressions
test "complex expression with multiple operations" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("2 + 3 * 4", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expect(value == .number);
}

test "assignment then use in expression" {
    const allocator = testing.allocator;

    var env = try Environment.init(allocator);
    defer env.deinit();

    // x := 10
    {
        const tokens = try @import("lexer.zig").tokenize("x := 10", allocator);
        defer @import("lexer.zig").freeTokens(tokens, allocator);

        var program = try @import("parser.zig").parse(tokens, allocator);
        defer program.deinit();

        _ = try evaluate(program, allocator, .{}, &env);
    }

    // x + 5
    {
        const tokens = try @import("lexer.zig").tokenize("x + 5", allocator);
        defer @import("lexer.zig").freeTokens(tokens, allocator);

        var program = try @import("parser.zig").parse(tokens, allocator);
        defer program.deinit();

        const value = try evaluate(program, allocator, .{}, &env);
        defer cleanupValue(allocator, value);

        try testing.expectEqual(@as(f64, 15.0), value.number);
    }
}

// Memory leak stress tests
test "no memory leaks on simple evaluation" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("5 + 3", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expectEqual(@as(f64, 8.0), value.number);
}

test "no memory leaks with Results" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("ok(5) + ok(3)", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expectEqual(@as(f64, 8.0), value.number);
}

test "no memory leaks with error propagation" {
    const allocator = testing.allocator;

    const tokens = try @import("lexer.zig").tokenize("err(\"test\") + 5", allocator);
    defer @import("lexer.zig").freeTokens(tokens, allocator);

    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    const value = try evaluate(program, allocator, .{}, null);
    defer cleanupValue(allocator, value);

    try testing.expect(value == .result);
    try testing.expect(value.result.isErr());
}

test "multiple assignments don't leak" {
    const allocator = testing.allocator;

    var env = try Environment.init(allocator);
    defer env.deinit();

    // Assign and reassign multiple times
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const tokens = try @import("lexer.zig").tokenize("x := 42", allocator);
        defer @import("lexer.zig").freeTokens(tokens, allocator);

        var program = try @import("parser.zig").parse(tokens, allocator);
        defer program.deinit();

        const result = try evaluate(program, allocator, .{}, &env);
        defer cleanupValue(allocator, result);
    }

    const stored = env.get("x").?;
    try testing.expectEqual(@as(f64, 42.0), stored.number);
}
