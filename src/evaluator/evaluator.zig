const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("types/ast");
const TokenType = @import("types/token").TokenType;
const Value = @import("evaluator/value").Value;
const ValueData = @import("evaluator/value").ValueData;
const Result = @import("evaluator/value").Result;
const Environment = @import("evaluator/environment").Environment;

pub const EvalError = error{
    OutOfMemory,
    InternalFault,
};

// ============================================================================
// Evaluator State
// ============================================================================

pub const EvalConfig = struct {
    enable_trace: bool = false,
};

const EvalState = struct {
    env: *Environment,
    result_allocator: Allocator, // For values that survive (final results)
    temp_allocator: Allocator, // For intermediate values (arena)
};

// ============================================================================
// Public API
// ============================================================================

/// Evaluate a program with two-allocator strategy
///
/// @param result_allocator: For final Values that survive (caller owns)
/// @param temp_allocator: For intermediate work (arena, can be reset)
/// @param env: Environment for variable storage
///
/// GUARANTEES:
/// - No allocations from temp_allocator survive this function
/// - Caller can reset temp_allocator after this returns
/// - Returned Value uses result_allocator (caller must free)
pub fn evaluate(
    program: Ast.Program,
    result_allocator: Allocator,
    temp_allocator: Allocator,
    config: EvalConfig,
    env: ?*Environment,
) EvalError!Value {
    _ = config;

    // If no environment provided, create temporary one
    var temp_env = if (env == null) try Environment.init(result_allocator) else null;
    defer if (temp_env) |*e| e.deinit();

    const active_env = env orelse &temp_env.?;

    var state = EvalState{
        .env = active_env,
        .result_allocator = result_allocator,
        .temp_allocator = temp_allocator,
    };

    var last_value = Value.initStack(.{ .none = {} });
    for (program.expressions) |expr| {
        last_value = try evalExpr(&state, expr);
    }

    return last_value;
}

// ============================================================================
// Expression Evaluation
// ============================================================================

fn evalExpr(state: *EvalState, expr: Ast.Expr) EvalError!Value {
    return switch (expr) {
        .literal => |lit| evalLiteral(state, lit),
        .identifier => |id| evalIdentifier(state, id),
        .assignment => |asgn| evalAssignment(state, asgn),
        .binary => |bin| evalBinary(state, bin),
        .unary => |un| evalUnary(state, un),
        .ok_expr => |ok_e| evalOk(state, ok_e),
        .err_expr => |err_e| evalErr(state, err_e),
        else => Value.initStack(.{ .none = {} }),
    };
}

fn evalLiteral(state: *EvalState, lit: Ast.Literal) EvalError!Value {
    return switch (lit) {
        .number => |n| Value.initStack(.{ .number = n }),
        .boolean => |b| Value.initStack(.{ .boolean = b }),
        .none => Value.initStack(.{ .none = {} }),
        .string => |s| blk: {
            // String literals need to be copied
            const str_copy = try state.temp_allocator.dupe(u8, s);
            break :blk Value.init(state.temp_allocator, .{ .string = str_copy });
        },
    };
}

fn evalIdentifier(state: *EvalState, name: []const u8) EvalError!Value {
    if (state.env.get(name)) |val| {
        // Environment returns a borrowed reference, so we clone it
        return try val.clone(state.result_allocator);
    }
    return try createErrorResult(state, "undefined variable");
}

fn evalAssignment(state: *EvalState, assign: Ast.AssignExpr) EvalError!Value {
    // Evaluate RHS (uses temp allocator)
    const rhs_value = try evalExpr(state, assign.value.*);

    // Environment.set() will clone the value, so it takes ownership
    try state.env.set(assign.name, rhs_value);

    // Return a clone for the caller using result allocator
    return try rhs_value.clone(state.result_allocator);
}

fn evalBinary(state: *EvalState, bin: Ast.BinaryExpr) EvalError!Value {
    // All intermediate values use temp allocator
    const left = try evalExpr(state, bin.left.*);
    const right = try evalExpr(state, bin.right.*);

    // Unwrap values (handles Results automatically)
    const left_unwrapped = try unwrapValue(left);
    const right_unwrapped = try unwrapValue(right);

    // Error propagation - just return the error
    if (left_unwrapped.data == .result) return left_unwrapped;
    if (right_unwrapped.data == .result) return right_unwrapped;

    // Dispatch based on operator
    return switch (bin.operator) {
        .PLUS => try evalAdd(state, left_unwrapped, right_unwrapped),
        .MINUS => try evalSub(state, left_unwrapped, right_unwrapped),
        .STAR => try evalMul(state, left_unwrapped, right_unwrapped),
        .SLASH => try evalDiv(state, left_unwrapped, right_unwrapped),
        .EQUAL_EQUAL => try evalEq(state, left_unwrapped, right_unwrapped),
        .BANG_EQUAL => try evalNeq(state, left_unwrapped, right_unwrapped),
        .LESS => try evalLess(state, left_unwrapped, right_unwrapped),
        .LESS_EQUAL => try evalLessEq(state, left_unwrapped, right_unwrapped),
        .GREATER => try evalGreater(state, left_unwrapped, right_unwrapped),
        .GREATER_EQUAL => try evalGreaterEq(state, left_unwrapped, right_unwrapped),
        else => try createErrorResult(state, "unknown operator"),
    };
}

fn evalUnary(state: *EvalState, un: Ast.UnaryExpr) EvalError!Value {
    const operand = try evalExpr(state, un.operand.*);
    const unwrapped = try unwrapValue(operand);

    if (unwrapped.data == .result) return unwrapped;

    return switch (un.operator) {
        .MINUS => blk: {
            if (unwrapped.data != .number) {
                break :blk try createErrorResult(state, "unary minus requires number");
            }
            break :blk Value.initStack(.{ .number = -unwrapped.data.number });
        },
        .BANG => blk: {
            if (unwrapped.data != .boolean) {
                break :blk try createErrorResult(state, "logical not requires boolean");
            }
            break :blk Value.initStack(.{ .boolean = !unwrapped.data.boolean });
        },
        else => try createErrorResult(state, "unknown unary operator"),
    };
}

fn evalOk(state: *EvalState, ok_expr: *Ast.Expr) EvalError!Value {
    const inner = try evalExpr(state, ok_expr.*);
    const result = try Result.initOk(state.result_allocator, inner);
    return Value.init(state.result_allocator, .{ .result = result });
}

fn evalErr(state: *EvalState, err_expr: *Ast.Expr) EvalError!Value {
    const inner = try evalExpr(state, err_expr.*);
    const unwrapped = try unwrapValue(inner);

    if (unwrapped.data == .result) return unwrapped;

    if (unwrapped.data != .string) {
        return try createErrorResult(state, "err() requires string argument");
    }

    const result = try Result.initErr(state.result_allocator, unwrapped.data.string);
    return Value.init(state.result_allocator, .{ .result = result });
}

// ============================================================================
// Binary Operators
// ============================================================================

fn evalAdd(state: *EvalState, left: Value, right: Value) EvalError!Value {
    // Number addition
    if (left.data == .number and right.data == .number) {
        return Value.initStack(.{ .number = left.data.number + right.data.number });
    }

    // String concatenation
    if (left.data == .string and right.data == .string) {
        const result = try std.fmt.allocPrint(
            state.result_allocator,
            "{s}{s}",
            .{ left.data.string, right.data.string },
        );
        return Value.init(state.result_allocator, .{ .string = result });
    }

    return try createErrorResult(state, "type mismatch in addition");
}

fn evalSub(state: *EvalState, left: Value, right: Value) EvalError!Value {
    if (left.data != .number or right.data != .number) {
        return try createErrorResult(state, "subtraction requires numbers");
    }
    return Value.initStack(.{ .number = left.data.number - right.data.number });
}

fn evalMul(state: *EvalState, left: Value, right: Value) EvalError!Value {
    if (left.data != .number or right.data != .number) {
        return try createErrorResult(state, "multiplication requires numbers");
    }
    return Value.initStack(.{ .number = left.data.number * right.data.number });
}

fn evalDiv(state: *EvalState, left: Value, right: Value) EvalError!Value {
    if (left.data != .number or right.data != .number) {
        return try createErrorResult(state, "division requires numbers");
    }
    if (right.data.number == 0) {
        return try createErrorResult(state, "division by zero");
    }
    return Value.initStack(.{ .number = left.data.number / right.data.number });
}

fn evalEq(state: *EvalState, left: Value, right: Value) EvalError!Value {
    _ = state;
    return Value.initStack(.{ .boolean = left.eql(right) });
}

fn evalNeq(state: *EvalState, left: Value, right: Value) EvalError!Value {
    _ = state;
    return Value.initStack(.{ .boolean = !left.eql(right) });
}

fn evalLess(state: *EvalState, left: Value, right: Value) EvalError!Value {
    if (left.data != .number or right.data != .number) {
        return try createErrorResult(state, "comparison requires numbers");
    }
    return Value.initStack(.{ .boolean = left.data.number < right.data.number });
}

fn evalLessEq(state: *EvalState, left: Value, right: Value) EvalError!Value {
    if (left.data != .number or right.data != .number) {
        return try createErrorResult(state, "comparison requires numbers");
    }
    return Value.initStack(.{ .boolean = left.data.number <= right.data.number });
}

fn evalGreater(state: *EvalState, left: Value, right: Value) EvalError!Value {
    if (left.data != .number or right.data != .number) {
        return try createErrorResult(state, "comparison requires numbers");
    }
    return Value.initStack(.{ .boolean = left.data.number > right.data.number });
}

fn evalGreaterEq(state: *EvalState, left: Value, right: Value) EvalError!Value {
    if (left.data != .number or right.data != .number) {
        return try createErrorResult(state, "comparison requires numbers");
    }
    return Value.initStack(.{ .boolean = left.data.number >= right.data.number });
}

// ============================================================================
// Helpers
// ============================================================================

/// Unwrap a Value - if it's a Result.ok, extract the inner value
/// If it's a Result.err, return it wrapped as a Value
fn unwrapValue(value: Value) EvalError!Value {
    if (value.data != .result) return value;

    const result = value.data.result;
    if (result.isOk()) {
        return result.payload.ok;
    } else {
        // Return error as-is (wrapped in Value)
        return value;
    }
}

/// Create an error Result wrapped in a Value
fn createErrorResult(state: *EvalState, msg: []const u8) EvalError!Value {
    const result = try Result.initErr(state.result_allocator, msg);
    return Value.init(state.result_allocator, .{ .result = result });
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "simple arithmetic" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer").tokenize("2 + 3", arena.allocator());
    const program = try @import("parser").parse(tokens, arena.allocator());

    const value = try evaluate(program, allocator, arena.allocator(), .{}, null);
    defer value.deinit();

    try testing.expectEqual(@as(f64, 5.0), value.data.number);
}

test "string concatenation" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer").tokenize("\"hello\" + \" world\"", arena.allocator());
    const program = try @import("parser").parse(tokens, arena.allocator());

    const value = try evaluate(program, allocator, arena.allocator(), .{}, null);
    defer value.deinit();

    try testing.expectEqualStrings("hello world", value.data.string);
}

test "assignment and retrieval" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try Environment.init(allocator);
    defer env.deinit();

    // Assign
    {
        const tokens = try @import("lexer").tokenize("x := 42", arena.allocator());
        const program = try @import("parser").parse(tokens, arena.allocator());

        const value = try evaluate(program, allocator, arena.allocator(), .{}, &env);
        defer value.deinit();
    }

    // Retrieve
    {
        _ = arena.reset(.retain_capacity);
        const tokens = try @import("lexer").tokenize("x", arena.allocator());
        const program = try @import("parser").parse(tokens, arena.allocator());

        const value = try evaluate(program, allocator, arena.allocator(), .{}, &env);
        defer value.deinit();

        try testing.expectEqual(@as(f64, 42.0), value.data.number);
    }
}

test "ok() creates Result" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer").tokenize("ok(42)", arena.allocator());
    const program = try @import("parser").parse(tokens, arena.allocator());

    const value = try evaluate(program, allocator, arena.allocator(), .{}, null);
    defer value.deinit();

    try testing.expect(value.data == .result);
    try testing.expect(value.data.result.isOk());
    try testing.expectEqual(@as(f64, 42.0), value.data.result.payload.ok.data.number);
}

test "err() creates error Result" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer").tokenize("err(\"failed\")", arena.allocator());
    const program = try @import("parser").parse(tokens, arena.allocator());

    const value = try evaluate(program, allocator, arena.allocator(), .{}, null);
    defer value.deinit();

    try testing.expect(value.data == .result);
    try testing.expect(value.data.result.isErr());
    try testing.expectEqualStrings("failed", value.data.result.payload.err.message);
}

test "division by zero returns error" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer").tokenize("10 / 0", arena.allocator());
    const program = try @import("parser").parse(tokens, arena.allocator());

    const value = try evaluate(program, allocator, arena.allocator(), .{}, null);
    defer value.deinit();

    try testing.expect(value.data == .result);
    try testing.expect(value.data.result.isErr());
}

test "no memory leaks with multiple evaluations" {
    const allocator = testing.allocator;

    for (0..100) |_| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const tokens = try @import("lexer").tokenize("2 + 3 * 4", arena.allocator());
        const program = try @import("parser").parse(tokens, arena.allocator());

        const value = try evaluate(program, allocator, arena.allocator(), .{}, null);
        defer value.deinit();

        try testing.expectEqual(@as(f64, 14.0), value.data.number);
    }
}
