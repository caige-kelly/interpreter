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

// ============================================================================
// Core Types
// ============================================================================

pub const Value = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    none: void,
    result: ResultValue,

    pub fn format(
        self: Value,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .number => |n| try writer.print("{d}", .{n}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .boolean => |b| try writer.print("{}", .{b}),
            .none => try writer.writeAll("none"),
            .result => |r| try writer.print("Result({s})", .{@tagName(r.tag)}),
        }
    }
};

pub const Metadata = struct {
    timestamp: i64,
    duration_ns: u64,
    expr_source: []const u8,
    extra: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(expr_source: []const u8, allocator: std.mem.Allocator) Metadata {
        return .{
            .timestamp = std.time.milliTimestamp(),
            .duration_ns = 0,
            .expr_source = expr_source,
            .extra = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn withDuration(self: Metadata, duration_ns: u64) Metadata {
        var m = self;
        m.duration_ns = duration_ns;
        return m;
    }

    pub fn set(self: *Metadata, key: []const u8, value: []const u8) !void {
        try self.extra.put(key, value);
    }

    pub fn get(self: *const Metadata, key: []const u8) ?[]const u8 {
        return self.extra.get(key);
    }

    pub fn deinit(self: *Metadata) void {
        self.extra.deinit();
    }
};

pub const ResultValue = struct {
    tag: Tag,
    value: ?*Value,
    msg: ?[]const u8,
    meta: Metadata,

    pub const Tag = enum { ok, err };

    pub fn ok(val: *Value, meta: Metadata) ResultValue {
        return .{ .tag = .ok, .value = val, .msg = null, .meta = meta };
    }

    pub fn err(msg: []const u8, meta: Metadata) ResultValue {
        return .{ .tag = .err, .value = null, .msg = msg, .meta = meta };
    }

    pub fn isOk(self: ResultValue) bool {
        return self.tag == .ok;
    }

    pub fn isErr(self: ResultValue) bool {
        return self.tag == .err;
    }

    pub fn deinit(self: ResultValue) void {
        if (self.value) |v| {
            self.meta.allocator.destroy(v);
        }
        // optionally free metadata internals here later
    }
};

pub const EvalConfig = struct {
    enable_trace: bool = false,
};

pub const TraceEntry = struct {
    result: ResultValue,
    task_id: usize = 0,
};

pub const EvaluationResult = struct {
    result: ResultValue, // Changed from value: Value
    trace: []const TraceEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EvaluationResult) void {
        self.allocator.free(self.trace);
        // Note: result.meta cleanup happens when destroying result values
    }
};

// Pure data - evaluation state
const EvalState = struct {
    globals: std.StringHashMap(ResultValue), // Changed from Value to ResultValue
    results: std.ArrayList(TraceEntry),
    config: EvalConfig,
    allocator: std.mem.Allocator,
};

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn evaluate(
    program: Ast.Program,
    allocator: std.mem.Allocator,
    config: EvalConfig,
) !EvaluationResult {
    var state = EvalState{
        .globals = std.StringHashMap(ResultValue).init(allocator),
        .results = try std.ArrayList(TraceEntry).initCapacity(allocator, 16),
        .config = config,
        .allocator = allocator,
    };
    defer state.globals.deinit();
    defer state.results.deinit(allocator);

    // Default: none result
    var last_result = blk: {
        const val_ptr = try allocator.create(Value);
        val_ptr.* = Value{ .none = {} };
        const meta = Metadata.init("program", allocator);
        break :blk ResultValue.ok(val_ptr, meta);
    };

    for (program.expressions) |expr| {
        last_result = try evalExpr(&state, expr);

        if (state.config.enable_trace) {
            try state.results.append(allocator, .{ .result = last_result });
        }

        // Early exit on error (unless we want to continue)
        if (last_result.isErr()) {
            break;
        }
    }

    // Copy trace to return (owned by caller)
    const trace_copy = try allocator.alloc(TraceEntry, state.results.items.len);
    @memcpy(trace_copy, state.results.items);

    return EvaluationResult{
        .result = last_result,
        .trace = trace_copy,
        .allocator = allocator,
    };
}

// ============================================================================
// Expression Evaluation
// ============================================================================

fn evalExpr(state: *EvalState, expr: Ast.Expr) EvalError!ResultValue {
    const start = std.time.nanoTimestamp();

    var result = switch (expr) {
        .literal => |lit| try evalLiteral(state, lit),
        .identifier => |name| try evalIdentifier(state, name),
        .assignment => |assign| try evalAssignment(state, assign),
        .binary => |bin| try evalBinary(state, bin),
        .unary => |un| try evalUnary(state, un),
        .pipe => |pipe| try evalPipe(state, pipe),
        .policy => |pol| try evalPolicy(state, pol),
    };

    // Update duration in metadata
    const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start));
    result.meta = result.meta.withDuration(duration);

    return result;
}

fn evalLiteral(state: *EvalState, lit: Ast.Literal) EvalError!ResultValue {
    const val_ptr = try state.allocator.create(Value);
    val_ptr.* = switch (lit) {
        .string => |s| Value{ .string = s },
        .number => |n| Value{ .number = n },
        .boolean => |b| Value{ .boolean = b },
        .none => Value{ .none = {} },
    };

    const meta = Metadata.init("literal", state.allocator);
    return ResultValue.ok(val_ptr, meta);
}

fn evalIdentifier(state: *EvalState, name: []const u8) EvalError!ResultValue {
    const meta = Metadata.init("identifier", state.allocator);

    if (state.globals.get(name)) |result| {
        return result;
    } else {
        return ResultValue.err("undefined variable", meta);
    }
}

fn evalAssignment(state: *EvalState, assign: Ast.AssignExpr) EvalError!ResultValue {
    const meta = Metadata.init("assignment", state.allocator);

    if (state.globals.contains(assign.name)) {
        return ResultValue.err("variable already defined", meta);
    }

    const rhs = try evalExpr(state, assign.value.*);

    if (rhs.isErr()) return rhs;

    // auto-unwrap ok(...)
    const unwrapped = if (rhs.value) |v| v.* else Value.none;
    const val_ptr = try state.allocator.create(Value);
    val_ptr.* = unwrapped;

    const wrapped = ResultValue.ok(val_ptr, rhs.meta);
    try state.globals.put(assign.name, wrapped);

    return wrapped;
}

fn evalBinary(state: *EvalState, bin: Ast.BinaryExpr) EvalError!ResultValue {
    const meta = Metadata.init("binary", state.allocator);

    // Evaluate left side
    const left_result = try evalExpr(state, bin.left.*);
    if (left_result.isErr()) return left_result;

    // Evaluate right side
    const right_result = try evalExpr(state, bin.right.*);
    if (right_result.isErr()) return right_result;

    // Unwrap values
    const left = left_result.value.?.*;
    const right = right_result.value.?.*;

    // Perform operation based on operator
    const result_val = switch (bin.operator) {
        .PLUS => try evalAddition(state, left, right),
        .MINUS => try evalSubtraction(left, right),
        .STAR => try evalMultiplication(left, right),
        .SLASH => evalDivision(left, right),
        .EQUAL_EQUAL, .BANG_EQUAL => try evalEquality(left, right, bin.operator),
        .LESS, .LESS_EQUAL, .GREATER, .GREATER_EQUAL => try evalComparison(left, right, bin.operator),
        else => return ResultValue.err("unknown operator", meta),
    };

    const val_ptr = try state.allocator.create(Value);
    val_ptr.* = result_val;
    return ResultValue.ok(val_ptr, meta);
}

fn evalUnary(state: *EvalState, un: Ast.UnaryExpr) EvalError!ResultValue {
    const meta = Metadata.init("unary", state.allocator);

    // Evaluate operand
    const operand_result = try evalExpr(state, un.operand.*);
    if (operand_result.isErr()) return operand_result;

    const operand = operand_result.value.?.*;

    const result_val = switch (un.operator) {
        .MINUS => blk: {
            if (operand != .number) {
                return ResultValue.err("cannot negate non-number", meta);
            }
            break :blk Value{ .number = -operand.number };
        },
        else => return ResultValue.err("unknown unary operator", meta),
    };

    const val_ptr = try state.allocator.create(Value);
    val_ptr.* = result_val;
    return ResultValue.ok(val_ptr, meta);
}

fn evalPolicy(state: *EvalState, pol: Ast.Policy) EvalError!ResultValue {
    // Evaluate the inner expression first
    const inner = try evalExpr(state, pol.expr.*);

    switch (pol.policy) {
        .none => {
            // Normal unwrap — just pass through
            return inner;
        },
        .keep_wrapped => {
            // ^expr → keep the result exactly as-is (already wrapped)
            return inner;
        },
        .panic_on_error => {
            if (inner.isErr()) {
                // Tag the metadata so the runtime knows this was fatal.
                var meta = inner.meta;
                // Safe to ignore collision errors — if a severity already exists, overwrite.
                _ = meta.set("severity", "fatal") catch {};
                const msg = inner.msg orelse "fatal error";
                return ResultValue.err(msg, meta);
            }
            return inner;
        },
        .unwrap_or_none => {
            // ?expr → unwrap ok(), replace err() with ok(none)
            if (inner.isErr()) {
                const val_ptr = try state.allocator.create(Value);
                val_ptr.* = Value{ .none = {} };
                const meta = Metadata.init("unwrap_or_none", state.allocator);
                return ResultValue.ok(val_ptr, meta);
            }
            return inner;
        },
    }
}

// ============================================================================
// Operation Helpers
// ============================================================================

fn evalEquality(left: Value, right: Value, op: TokenType) EvalError!Value {
    const are_equal = switch (left) {
        .number => |l| if (right == .number) l == right.number else false,
        .string => |l| if (right == .string) std.mem.eql(u8, l, right.string) else false,
        .boolean => |l| if (right == .boolean) l == right.boolean else false,
        .none => right == .none,
        .result => false, // Results are not directly comparable
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

fn evalDivision(left: Value, right: Value) Value {
    if (right.number == 0) {
        return Value{ .boolean = false };
    }
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

fn evalPipe(state: *EvalState, pipe: Ast.PipeExpr) EvalError!ResultValue {
    const left_res = try evalExpr(state, pipe.left.*);

    // short-circuit if left failed
    if (left_res.isErr()) {
        var err_meta = left_res.meta;
        try err_meta.set("stage", "pipe-left");
        return ResultValue.err(left_res.msg orelse "pipeline short-circuited", err_meta);
    }

    const right_res = try evalExpr(state, pipe.right.*);

    // short-circuit if right failed
    if (right_res.isErr()) {
        var err_meta = right_res.meta;
        try err_meta.set("stage", "pipe-right");
        return right_res;
    }

    var merged_meta = right_res.meta;
    try merged_meta.set("kind", "pipe");

    // unwrap ok(...) to plain value, or default to none
    const unwrapped_value = if (right_res.value) |v| v.* else Value.none;

    // allocate new value node
    const val_ptr = try state.allocator.create(Value);
    val_ptr.* = unwrapped_value;

    return ResultValue.ok(val_ptr, merged_meta);
}

// ============================================================================
// Ripple Language Evaluation Tests
// All evaluation results return Result<Value, Err> — no Zig errors.
// ============================================================================

const testing = std.testing;

test "evaluate literal number returns Result" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("42", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var eval_result = try evaluate(program, arena.allocator(), .{});
    defer eval_result.deinit();

    try testing.expect(eval_result.result.isOk());
    try testing.expectEqual(@as(f64, 42.0), eval_result.result.value.?.number);
}

test "undefined variable returns error Result" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("y := unknown", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var eval_result = try evaluate(program, arena.allocator(), .{});
    defer eval_result.deinit();

    try testing.expect(eval_result.result.isErr());
    try testing.expectEqualStrings("undefined variable", eval_result.result.msg.?);
}

test "evaluate multiplication returns ok(12)" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := 3 * 4", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var eval_result = try evaluate(program, arena.allocator(), .{});
    defer eval_result.deinit();

    try testing.expect(eval_result.result.isOk());
    try testing.expectEqual(@as(f64, 12.0), eval_result.result.value.?.number);
}

test "division by zero returns err('division by zero')" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := 10 / 0", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var eval_result = try evaluate(program, arena.allocator(), .{});
    defer eval_result.deinit();

    try testing.expect(eval_result.result.isErr());
    try testing.expectEqualStrings("division by zero", eval_result.result.msg.?);
}

test "metadata tracks duration" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try @import("lexer.zig").tokenize("x := 5 + 3", arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var eval_result = try evaluate(program, arena.allocator(), .{});
    defer eval_result.deinit();

    try testing.expect(eval_result.result.isOk());
    try testing.expect(eval_result.result.meta.duration_ns > 0);
}

test "policy evaluation: question unwraps to none on error" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const src = "?unknown"; // undefined identifier
    const tokens = try @import("lexer.zig").tokenize(src, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try std.testing.expect(result.result.isOk());
    try std.testing.expectEqual(Value.none, result.result.value.?.*);
}

test "policy evaluation: bang panics on error (produces err)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src = "x := !undefinedVar";
    const tokens = try @import("lexer.zig").tokenize(src, allocator);
    var program = try @import("parser.zig").parse(tokens, allocator);
    defer program.deinit();

    var eval_res = try evaluate(program, allocator, .{});
    defer eval_res.deinit();

    try std.testing.expect(eval_res.result.isErr());
    try std.testing.expectEqualStrings("undefined variable", eval_res.result.msg.?);

    if (eval_res.result.meta.get("severity")) |sev| {
        try std.testing.expectEqualStrings("fatal", sev);
    }
}

test "policy evaluation: caret keeps wrapped ok(42)" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const src = "^42";
    const tokens = try @import("lexer.zig").tokenize(src, arena.allocator());
    var program = try @import("parser.zig").parse(tokens, arena.allocator());
    defer program.deinit();

    var result = try evaluate(program, arena.allocator(), .{});
    defer result.deinit();

    try std.testing.expect(result.result.isOk());
    try std.testing.expect(result.result.value != null);
    try std.testing.expectEqual(@as(f64, 42.0), result.result.value.?.number);
}

test "integration: literal vs assignment both return ok(5)" {
    const allocator = std.testing.allocator;

    // --- Case 1: literal
    {
        const src = "5";
        const tokens = try @import("lexer.zig").tokenize(src, allocator);
        defer allocator.free(tokens);
        var program = try @import("parser.zig").parse(tokens, allocator);
        defer program.deinit();

        var result = try evaluate(program, allocator, .{});
        defer result.deinit();

        try std.testing.expect(result.result.isOk());
        const val = result.result.value.?;
        try std.testing.expect(val.* == .number);
        try std.testing.expectEqual(@as(f64, 5.0), val.number);
    }

    // --- Case 2: assignment
    {
        const src = "x := 5";
        const tokens = try @import("lexer.zig").tokenize(src, allocator);
        defer allocator.free(tokens);
        var program = try @import("parser.zig").parse(tokens, allocator);
        defer program.deinit();

        var result = try evaluate(program, allocator, .{});
        defer result.deinit();

        try std.testing.expect(result.result.isOk());
        const val = result.result.value.?;
        try std.testing.expect(val.* == .number);
        try std.testing.expectEqual(@as(f64, 5.0), val.number);
    }
}
