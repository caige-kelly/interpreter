const std = @import("std");
const Ast = @import("ast.zig");
const TokenType = @import("token.zig").TokenType;

pub const EvalError = error{
    UndefinedVariable,
    VariableAlreadyDefined,
    ExpressionDontExist,
    OutOfMemory,
    TypeMismatch,
    DivisionByZero,
};

pub const ResultValue = struct {
    tag: Tag,
    user: ?*Value, // pointer to another Value
    sys: ?*Value,

    pub const Tag = enum { ok, err };

    pub fn ok(user: ?*Value, sys: ?*Value) ResultValue {
        return ResultValue{ .tag = .ok, .user = user, .sys = sys };
    }

    pub fn err(user: ?*Value, sys: ?*Value) ResultValue {
        return ResultValue{ .tag = .err, .user = user, .sys = sys };
    }
};

pub const Value = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    none,
    result: ResultValue,
};

pub const EvalConfig = struct {
    enable_trace: bool = false,
};

pub const TraceEntry = struct {
    result: Value,
    task_id: usize = 0,
};

pub const EvaluationResult = struct {
    value: Value,
    trace: []const TraceEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EvaluationResult) void {
        self.allocator.free(self.trace);
    }
};

// Pure data - evaluation state
const EvalState = struct {
    globals: std.StringHashMap(Value),
    results: std.ArrayList(TraceEntry),
    config: EvalConfig,
    allocator: std.mem.Allocator,
};

// Main entry point - free function
pub fn evaluate(
    program: Ast.Program,
    allocator: std.mem.Allocator,
    config: EvalConfig,
) !EvaluationResult {
    var state = EvalState{
        .globals = std.StringHashMap(Value).init(allocator),
        .results = try std.ArrayList(TraceEntry).initCapacity(allocator, 16),
        .config = config,
        .allocator = allocator,
    };
    defer state.globals.deinit();
    defer state.results.deinit(allocator);

    var last_value = Value{ .none = {} };

    for (program.expressions) |expr| {
        last_value = try evalExpr(&state, expr);

        if (state.config.enable_trace) {
            try state.results.append(allocator, .{ .result = last_value });
        }
    }

    // Copy trace to return (owned by caller)
    const trace_copy = try allocator.alloc(TraceEntry, state.results.items.len);
    @memcpy(trace_copy, state.results.items);

    return EvaluationResult{
        .value = last_value,
        .trace = trace_copy,
        .allocator = allocator,
    };
}

fn evalExpr(state: *EvalState, expr: Ast.Expr) EvalError!Value {
    return switch (expr) {
        .literal => |lit| evalLiteral(lit),
        .identifier => |name| evalIdentifier(state, name),
        .assignment => |assign| try evalAssignment(state, assign),
        .binary => |bin| try evalBinary(state, bin),
        .unary => |un| try evalUnary(state, un),
        //else => error.ExpressionDontExist,
    };
}

fn evalAssignment(state: *EvalState, assign: Ast.AssignExpr) EvalError!Value {
    if (state.globals.contains(assign.name)) {
        return error.VariableAlreadyDefined;
    }

    const value = try evalExpr(state, assign.value.*);
    try state.globals.put(assign.name, value);
    return value;
}

fn evalBinary(state: *EvalState, bin: Ast.BinaryExpr) EvalError!Value {
    const left = try evalExpr(state, bin.left.*);
    const right = try evalExpr(state, bin.right.*);

    // Dispatch based on operator category and operand types
    return switch (bin.operator) {
        // Equality operators - work on any matching types
        .EQUAL_EQUAL, .BANG_EQUAL => evalEquality(left, right, bin.operator),

        // Arithmetic operators - type-specific behavior
        .PLUS => evalAddition(state, left, right),
        .MINUS => evalSubtraction(left, right),
        .STAR => evalMultiplication(left, right),
        .SLASH => evalDivision(left, right),

        // Comparison operators - numbers only
        .LESS, .LESS_EQUAL, .GREATER, .GREATER_EQUAL => evalComparison(left, right, bin.operator),

        else => error.ExpressionDontExist,
    };
}

fn evalEquality(left: Value, right: Value, op: TokenType) EvalError!Value {
    const are_equal = switch (left) {
        .number => |l| if (right == .number) l == right.number else false,
        .string => |l| if (right == .string) std.mem.eql(u8, l, right.string) else false,
        .boolean => |l| if (right == .boolean) l == right.boolean else false,
        .none => right == .none,
        .result => false, // new case: Results are not comparable yet
    };

    return Value{ .boolean = if (op == .EQUAL_EQUAL) are_equal else !are_equal };
}

fn evalAddition(state: *EvalState, left: Value, right: Value) EvalError!Value {
    return switch (left) {
        .number => |l| blk: {
            if (right != .number) return error.TypeMismatch;
            break :blk Value{ .number = l + right.number };
        },
        .string => |l| blk: {
            if (right != .string) return error.TypeMismatch;
            // Concatenate strings
            const result = try std.fmt.allocPrint(state.allocator, "{s}{s}", .{ l, right.string });
            break :blk Value{ .string = result };
        },
        else => error.TypeMismatch,
    };
}

fn evalSubtraction(left: Value, right: Value) EvalError!Value {
    if (left != .number or right != .number) return error.TypeMismatch;
    return Value{ .number = left.number - right.number };
}

fn evalMultiplication(left: Value, right: Value) EvalError!Value {
    if (left != .number or right != .number) return error.TypeMismatch;
    return Value{ .number = left.number * right.number };
}

fn evalDivision(left: Value, right: Value) EvalError!Value {
    if (left != .number or right != .number) return error.TypeMismatch;
    if (right.number == 0) return error.DivisionByZero;
    return Value{ .number = left.number / right.number };
}

fn evalComparison(left: Value, right: Value, op: TokenType) EvalError!Value {
    if (left != .number or right != .number) return error.TypeMismatch;

    const result = switch (op) {
        .LESS => left.number < right.number,
        .LESS_EQUAL => left.number <= right.number,
        .GREATER => left.number > right.number,
        .GREATER_EQUAL => left.number >= right.number,
        else => unreachable,
    };

    return Value{ .boolean = result };
}

fn evalUnary(state: *EvalState, un: Ast.UnaryExpr) EvalError!Value {
    // First, evaluate the operand (it could be any expression!)
    const operand = try evalExpr(state, un.operand.*);

    return switch (un.operator) {
        .MINUS => blk: {
            if (operand != .number) return error.TypeMismatch;
            break :blk Value{ .number = -operand.number };
        },
        .BANG => blk: {
            if (operand != .boolean) return error.TypeMismatch;
            break :blk Value{ .boolean = !operand.boolean };
        },
        else => error.ExpressionDontExist,
    };
}

fn evalLiteral(lit: Ast.Literal) Value {
    return switch (lit) {
        .string => |s| Value{ .string = s },
        .number => |n| Value{ .number = n },
        .boolean => |b| Value{ .boolean = b },
        .none => Value{ .none = {} },
    };
}

fn evalIdentifier(state: *EvalState, name: []const u8) EvalError!Value {
    if (state.globals.get(name)) |value| {
        return value;
    } else {
        return error.UndefinedVariable;
    }
}

// Tests
const testing = std.testing;

test "evaluate literal number" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := 42", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expectEqual(@as(f64, 42.0), result.value.number);
}

test "undefined variable" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("y := unknown", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const result = evaluate(program, arena.allocator(), .{});
    try testing.expectError(error.UndefinedVariable, result);
}

test "evaluate multiplication" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := 3 * 4", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expectEqual(@as(f64, 12.0), result.value.number);
}

test "evaluate division" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := 10 / 2", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expectEqual(@as(f64, 5.0), result.value.number);
}

test "evaluate with trace enabled" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := 10\ny := 20", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{ .enable_trace = true });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.trace.len);
    try testing.expectEqual(@as(f64, 10.0), result.trace[0].result.number);
    try testing.expectEqual(@as(f64, 20.0), result.trace[1].result.number);
}

test "evaluate binary addition" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "sum := 2 + 3";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expectEqual(@as(f64, 5.0), result.value.number);
}

test "evaluate binary subtraction" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "diff := 10 - 3";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expectEqual(@as(f64, 7.0), result.value.number);
}

test "evaluate mixed arithmetic with correct precedence" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "result := 2 + 3 * 4";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    // Should be 14 (3*4=12, then 2+12=14), NOT 20 (2+3=5, then 5*4=20)
    try testing.expectEqual(@as(f64, 14.0), result.value.number);
}

test "evaluate complex arithmetic precedence" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "result := 20 - 6 / 2 + 3 * 4";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    // Should be: 20 - (6/2) + (3*4) = 20 - 3 + 12 = 29
    try testing.expectEqual(@as(f64, 29.0), result.value.number);
}

test "evaluate equality comparison - true" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "result := 5 == 5";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .boolean);
    try testing.expect(result.value.boolean == true);
}

test "evaluate inequality comparison" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "result := 5 != 3";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .boolean);
    try testing.expect(result.value.boolean == true);
}

test "evaluate less than comparison" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "result := 3 < 5";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .boolean);
    try testing.expect(result.value.boolean == true);
}

test "evaluate greater than comparison" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "result := 5 > 3";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .boolean);
    try testing.expect(result.value.boolean == true);
}

test "evaluate less than or equal comparison" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "result := 3 <= 5";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .boolean);
    try testing.expect(result.value.boolean == true);
}

test "evaluate greater than or equal comparison" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "result := 5 >= 3";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .boolean);
    try testing.expect(result.value.boolean == true);
}

test "evaluate string equality" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "result := \"hello\" == \"hello\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .boolean);
    try testing.expect(result.value.boolean == true);
}

test "evaluate string concatenation" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "result := \"hello\" + \" world\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .string);
    try testing.expectEqualStrings("hello world", result.value.string);
}

test "evaluate string inequality" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "result := \"hello\" != \"world\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .boolean);
    try testing.expect(result.value.boolean == true);
}

test "evaluate negative number literal" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := -42";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expectEqual(@as(f64, -42.0), result.value.number);
}

test "evaluate negative number in expression" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := 5 + -3";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expectEqual(@as(f64, 2.0), result.value.number);
}

test "evaluate very small float" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := 0.0000001";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expectEqual(@as(f64, 0.0000001), result.value.number);
}

test "evaluate very large number" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := 999999999999.99";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expectEqual(@as(f64, 999999999999.99), result.value.number);
}

test "evaluate subtraction associativity" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := 10 - 5 - 2";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    // Should be left-to-right: (10 - 5) - 2 = 3
    try testing.expectEqual(@as(f64, 3.0), result.value.number);
}

test "evaluate division associativity" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := 20 / 4 / 2";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    // Should be left-to-right: (20 / 4) / 2 = 2.5
    try testing.expectEqual(@as(f64, 2.5), result.value.number);
}

test "evaluate empty string" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := \"\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .string);
    try testing.expectEqualStrings("", result.value.string);
}

test "evaluate empty string concatenation" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := \"\" + \"hello\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .string);
    try testing.expectEqualStrings("hello", result.value.string);
}

test "evaluate string with escape sequences" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := \"hello\\nworld\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .string);
    try testing.expectEqualStrings("hello\nworld", result.value.string);
}

test "evaluate string with tab escape" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := \"name:\\tvalue\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .string);
    try testing.expectEqualStrings("name:\tvalue", result.value.string);
}

test "evaluate string with escaped quote" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := \"say \\\"hello\\\"\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .string);
    try testing.expectEqualStrings("say \"hello\"", result.value.string);
}

test "evaluate string with backslash" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := \"path\\\\to\\\\file\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .string);
    try testing.expectEqualStrings("path\\to\\file", result.value.string);
}

test "error on adding string to number" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := 5 + \"hello\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const result = evaluate(program, arena.allocator(), .{});

    try testing.expectError(error.TypeMismatch, result);
}

test "error on multiplying strings" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := \"hello\" * \"world\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const result = evaluate(program, arena.allocator(), .{});

    try testing.expectError(error.TypeMismatch, result);
}

test "error on comparing string to number" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := 5 < \"hello\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const result = evaluate(program, arena.allocator(), .{});

    try testing.expectError(error.TypeMismatch, result);
}

test "error on undefined variable" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := y + 1";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const result = evaluate(program, arena.allocator(), .{});

    try testing.expectError(error.UndefinedVariable, result);
}

test "error on undefined variable in comparison" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := unknown > 5";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const result = evaluate(program, arena.allocator(), .{});

    try testing.expectError(error.UndefinedVariable, result);
}

test "error on variable redefinition (no shadowing allowed)" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\x := 10
        \\x := 20
    ;
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const result = evaluate(program, arena.allocator(), .{});

    try testing.expectError(error.VariableAlreadyDefined, result);
}

test "error on shadowing with expression" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\count := 1
        \\count := count + 1
    ;
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const result = evaluate(program, arena.allocator(), .{});

    try testing.expectError(error.VariableAlreadyDefined, result);
}

test "error on shadowing with different type" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\x := 42
        \\x := "now a string"
    ;
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    const result = evaluate(program, arena.allocator(), .{});

    try testing.expectError(error.VariableAlreadyDefined, result);
}

test "equality of different types returns false" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := 5 == \"5\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .boolean);
    try testing.expect(result.value.boolean == false);
}

test "inequality of different types returns true" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := 5 != \"5\"";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .boolean);
    try testing.expect(result.value.boolean == true);
}

test "boolean equality" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := true == true";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .boolean);
    try testing.expect(result.value.boolean == true);
}

test "boolean inequality" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := true != false";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .boolean);
    try testing.expect(result.value.boolean == true);
}

test "none equality" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := none == none";
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expect(result.value == .boolean);
    try testing.expect(result.value.boolean == true);
}

test "evaluate negation of variable" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\y := 10
        \\x := -y
    ;
    const tokens = try @import("lexer.zig").tokenize(source, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try testing.expectEqual(@as(f64, -10.0), result.value.number);
}

test "ResultValue constructs and distinguishes ok/err" {
    const allocator = testing.allocator;

    const v_none = try allocator.create(Value);
    v_none.* = Value.none;
    defer allocator.destroy(v_none);

    const ok_val = Value{ .result = ResultValue.ok(v_none, null) };
    const err_val = Value{ .result = ResultValue.err(v_none, null) };

    try testing.expect(ok_val.result.tag == .ok);
    try testing.expect(err_val.result.tag == .err);
}
