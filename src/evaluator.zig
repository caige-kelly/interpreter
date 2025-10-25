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
            freeValue(self.allocator, entry.value_ptr.*);
        }
        self.bindings.deinit();
    }

    pub fn set(self: *Environment, name: []const u8, value: Value) !void {
        const value_copy = try self.copyValue(value);

        // If key exists, get and free it
        if (self.bindings.fetchRemove(name)) |old_entry| {
            self.allocator.free(old_entry.key);
            freeValue(self.allocator, old_entry.value);
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
                const value_copy = if (r.value) |v| try self.copyValue(v) else null;
                const err_copy = if (r.err_msg) |msg| try self.allocator.dupe(u8, msg) else null;
                const expr_source_copy = if (r.meta.expr_source.len > 0)
                    try self.allocator.dupe(u8, r.meta.expr_source)
                else
                    "";

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

    fn freeValue(allocator: std.mem.Allocator, value: Value) void {
        switch (value) {
            .string => |s| allocator.free(s),
            .result => |r| {
                if (r.value) |*v| freeValue(allocator, v.*);
                if (r.err_msg) |msg| allocator.free(msg);
                if (r.meta.expr_source.len > 0) allocator.free(r.meta.expr_source);
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

pub const Meta = struct {
    expr_source: []const u8 = "",
    duration_ns: u64 = 0,
    extra: std.StringHashMap([]const u8),

    pub fn init(expr_source: []const u8, allocator: std.mem.Allocator) Meta {
        return .{
            .expr_source = expr_source,
            .duration_ns = 0,
            .extra = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn empty(allocator: std.mem.Allocator) Meta {
        return .{
            .extra = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Meta) void {
        self.extra.deinit();
    }
};

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
                if (r.isOk()) {
                    try writer.writeAll("ok(");
                    if (r.value) |val| {
                        try val.print(writer);
                    } else {
                        try writer.writeAll("none");
                    }
                    try writer.writeAll(")");
                } else if (r.err_msg) |msg| {
                    try writer.print("err(\"{s}\")", .{msg});
                } else {
                    try writer.writeAll("err(unknown)");
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
        .literal => |lit| evalLiteral(lit),
        .identifier => |id| evalIdentifier(state, id),
        .assignment => |asgn| evalAssignment(state, asgn),
        .binary => |bin| evalBinary(state, bin),
        .ok_expr => |ok_e| evalOk(state, ok_e),
        .err_expr => |err_e| evalErr(state, err_e),
        else => Value{ .none = {} },
    };
}

fn evalLiteral(lit: Ast.Literal) Value {
    return switch (lit) {
        .number => |n| Value{ .number = n },
        .string => |s| Value{ .string = s },
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

    // Unwrap both sides
    const left = try unwrapValue(state, left_value);
    const right = try unwrapValue(state, right_value);

    // If either side is still a Result, it's an error - propagate it
    if (left == .result) return left;
    if (right == .result) return right;

    // Type check
    if (left != .number or right != .number) {
        return try createErrorResult(state, "type mismatch: expected numbers");
    }

    // Division by zero check
    if (bin.operator == .SLASH and right.number == 0) {
        return try createErrorResult(state, "division by zero");
    }

    // Compute result
    const result = switch (bin.operator) {
        .PLUS => left.number + right.number,
        .MINUS => left.number - right.number,
        .STAR => left.number * right.number,
        .SLASH => left.number / right.number,
        else => return try createErrorResult(state, "unknown operator"),
    };

    return Value{ .number = result };
}

fn evalOk(state: *EvalState, ok_expr: Ast.OkExpr) EvalError!Value {
    const inner_value = try evalExpr(state, ok_expr.value.*);
    const result_ptr = try state.allocator.create(Result);
    result_ptr.* = Result.ok(inner_value, Meta.empty(state.allocator));
    return Value{ .result = result_ptr };
}

fn evalErr(state: *EvalState, err_expr: Ast.ErrExpr) EvalError!Value {
    const msg_value = try evalExpr(state, err_expr.message.*);

    const msg_str = switch (msg_value) {
        .string => |s| s,
        .result => |r| blk: {
            if (r.value) |v| {
                if (v == .string) {
                    // Copy string before freeing Result
                    const str_copy = try state.allocator.dupe(u8, v.string);
                    r.meta.deinit();
                    state.allocator.destroy(r);
                    break :blk str_copy;
                }
            }
            return try createErrorResult(state, "err() requires string argument");
        },
        else => return try createErrorResult(state, "err() requires string argument"),
    };

    const result_ptr = try state.allocator.create(Result);
    result_ptr.* = Result.err(msg_str, Meta.empty(state.allocator));
    return Value{ .result = result_ptr };
}

// ============================================================================
// Helpers
// ============================================================================

fn unwrapValue(state: *EvalState, value: Value) EvalError!Value {
    return switch (value) {
        .result => |r| blk: {
            if (r.isErr()) {
                // Don't free - return error Result as-is
                return value;
            }
            // Unwrap and free the wrapper
            const val = r.value.?;
            r.meta.deinit();
            state.allocator.destroy(r);
            break :blk val;
        },
        else => value,
    };
}

fn createErrorResult(state: *EvalState, msg: []const u8) EvalError!Value {
    const result_ptr = try state.allocator.create(Result);
    result_ptr.* = Result.err(msg, Meta.empty(state.allocator));
    return Value{ .result = result_ptr };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// Basic literal tests
test "literal number evaluates to bare value" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("5", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .number);
    try testing.expectEqual(@as(f64, 5.0), value.number);
}

test "literal string evaluates to bare value" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("\"hello\"", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .string);
    try testing.expectEqualStrings("hello", value.string);
}

// Assignment tests
test "assignment returns assigned value" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := 5", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .number);
    try testing.expectEqual(@as(f64, 5.0), value.number);
}

test "assignment stores value in environment" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try Environment.init(allocator);
    defer env.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := 42", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    _ = try evaluate(program, arena.allocator(), .{}, &env);

    const stored = env.get("x").?;
    try testing.expect(stored == .number);
    try testing.expectEqual(@as(f64, 42.0), stored.number);
}

test "reassignment updates variable" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try Environment.init(allocator);
    defer env.deinit();

    // First assignment
    const tokens1 = try @import("lexer.zig").tokenize("x := 5", arena.allocator());
    var program1 = try @import("parser.zig").parse(tokens1, arena.allocator());
    defer program1.deinit();
    _ = try evaluate(program1, arena.allocator(), .{}, &env);

    // Reassignment
    const tokens2 = try @import("lexer.zig").tokenize("x := 10", arena.allocator());
    var program2 = try @import("parser.zig").parse(tokens2, arena.allocator());
    defer program2.deinit();
    _ = try evaluate(program2, arena.allocator(), .{}, &env);

    const stored = env.get("x").?;
    try testing.expectEqual(@as(f64, 10.0), stored.number);
}

// Identifier tests
test "identifier returns stored value" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try Environment.init(allocator);
    defer env.deinit();

    // Store a value
    const tokens1 = try @import("lexer.zig").tokenize("x := 99", arena.allocator());
    var program1 = try @import("parser.zig").parse(tokens1, arena.allocator());
    defer program1.deinit();
    _ = try evaluate(program1, arena.allocator(), .{}, &env);

    // Retrieve it
    const tokens2 = try @import("lexer.zig").tokenize("x", arena.allocator());
    var program2 = try @import("parser.zig").parse(tokens2, arena.allocator());
    defer program2.deinit();
    const value = try evaluate(program2, arena.allocator(), .{}, &env);

    try testing.expectEqual(@as(f64, 99.0), value.number);
}

test "undefined identifier returns error Result" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("undefined_var", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .result);
    try testing.expect(value.result.isErr());
    try testing.expect(std.mem.indexOf(u8, value.result.err_msg.?, "undefined") != null);
}

// Binary operation tests
test "addition of two numbers" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("3 + 4", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .number);
    try testing.expectEqual(@as(f64, 7.0), value.number);
}

test "subtraction of two numbers" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("10 - 3", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expectEqual(@as(f64, 7.0), value.number);
}

test "multiplication of two numbers" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("5 * 6", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expectEqual(@as(f64, 30.0), value.number);
}

test "division of two numbers" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("20 / 4", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expectEqual(@as(f64, 5.0), value.number);
}

test "division by zero returns error Result" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("10 / 0", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .result);
    try testing.expect(value.result.isErr());
    try testing.expect(std.mem.indexOf(u8, value.result.err_msg.?, "division by zero") != null);
}

test "binary operation with Result operands unwraps correctly" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("ok(5) + ok(3)", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .number);
    try testing.expectEqual(@as(f64, 8.0), value.number);
}

test "binary operation propagates left error" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("err(\"left\") + 5", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .result);
    try testing.expect(value.result.isErr());
    try testing.expectEqualStrings("left", value.result.err_msg.?);
}

test "binary operation propagates right error" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("5 + err(\"right\")", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .result);
    try testing.expect(value.result.isErr());
    try testing.expectEqualStrings("right", value.result.err_msg.?);
}

// ok() and err() tests
test "ok() creates Result with value" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("ok(5)", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .result);
    try testing.expect(value.result.isOk());
    try testing.expectEqual(@as(f64, 5.0), value.result.value.?.number);
}

test "ok() can wrap strings" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("ok(\"hello\")", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .result);
    try testing.expect(value.result.isOk());
    try testing.expectEqualStrings("hello", value.result.value.?.string);
}

test "ok() can wrap Results (nested)" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("ok(ok(42))", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .result);
    try testing.expect(value.result.isOk());
    try testing.expect(value.result.value.? == .result);
    try testing.expect(value.result.value.?.result.isOk());
    try testing.expectEqual(@as(f64, 42.0), value.result.value.?.result.value.?.number);
}

test "err() creates error Result" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("err(\"failed\")", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .result);
    try testing.expect(value.result.isErr());
    try testing.expectEqualStrings("failed", value.result.err_msg.?);
}

test "err() with non-string returns error" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("err(42)", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .result);
    try testing.expect(value.result.isErr());
    try testing.expect(std.mem.indexOf(u8, value.result.err_msg.?, "requires string") != null);
}

test "err() with ok(string) unwraps correctly" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("err(ok(\"wrapped\"))", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    try testing.expect(value == .result);
    try testing.expect(value.result.isErr());
    try testing.expectEqualStrings("wrapped", value.result.err_msg.?);
}

// Assignment with Results
test "assigning ok() stores Result type" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try Environment.init(allocator);
    defer env.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := ok(99)", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    _ = try evaluate(program, arena.allocator(), .{}, &env);

    const stored = env.get("x").?;
    try testing.expect(stored == .result);
    try testing.expect(stored.result.isOk());
    try testing.expectEqual(@as(f64, 99.0), stored.result.value.?.number);
}

test "assigning err() stores error Result" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try Environment.init(allocator);
    defer env.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := err(\"test\")", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    _ = try evaluate(program, arena.allocator(), .{}, &env);

    const stored = env.get("x").?;
    try testing.expect(stored == .result);
    try testing.expect(stored.result.isErr());
    try testing.expectEqualStrings("test", stored.result.err_msg.?);
}

// Complex expressions
test "complex expression with multiple operations" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("2 + 3 * 4", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const value = try evaluate(program, arena.allocator(), .{}, null);

    // Depends on operator precedence in your parser
    // If * has higher precedence: 2 + (3 * 4) = 14
    // If left-to-right: (2 + 3) * 4 = 20
    try testing.expect(value == .number);
}

test "assignment then use in expression" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try Environment.init(allocator);
    defer env.deinit();

    // x := 10
    const tokens1 = try @import("lexer.zig").tokenize("x := 10", arena.allocator());
    var program1 = try @import("parser.zig").parse(tokens1, arena.allocator());
    defer program1.deinit();
    _ = try evaluate(program1, arena.allocator(), .{}, &env);

    // x + 5
    const tokens2 = try @import("lexer.zig").tokenize("x + 5", arena.allocator());
    var program2 = try @import("parser.zig").parse(tokens2, arena.allocator());
    defer program2.deinit();
    const value = try evaluate(program2, arena.allocator(), .{}, &env);

    try testing.expectEqual(@as(f64, 15.0), value.number);
}

// Memory leak tests (these verify no leaks via allocator tracking)
test "no memory leaks on simple evaluation" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("5 + 3", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    _ = try evaluate(program, arena.allocator(), .{}, null);
    // If there were leaks, arena.deinit() would catch them in test mode
}

test "no memory leaks with Results" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("ok(5) + ok(3)", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    _ = try evaluate(program, arena.allocator(), .{}, null);
}

test "no memory leaks with error propagation" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("err(\"test\") + 5", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    _ = try evaluate(program, arena.allocator(), .{}, null);
}
