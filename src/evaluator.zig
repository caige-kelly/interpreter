const std = @import("std");
const Ast = @import("ast.zig");

pub const EvalError = error{ UndefinedVariable, VariableAlreadyDefined, ExpressionDontExist, OutOfMemory };

pub const Value = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    none,
};

pub const EvalConfig = struct { enable_trace: bool = false };

pub const EvalResult = struct {
    result: Value,
};

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    globals: std.StringHashMap(Value), // name → value mapping
    config: EvalConfig,
    results: std.ArrayList(EvalResult),

    pub fn init(alloc: std.mem.Allocator, config: EvalConfig) !Evaluator {
        //alloc is an areana

        const g = std.StringHashMap(Value).init(alloc);
        const r = try std.ArrayList(EvalResult).initCapacity(alloc, 16); //init depreicated in zig 15.1

        return .{ .allocator = alloc, .globals = g, .config = config, .results = r };
    }

    pub fn deinit(self: *Evaluator) void {
        self.globals.deinit();
        self.results.deinit();
    }

    // Functions that evaluate different AST nodes
    pub fn evaluate(self: *Evaluator, program: Ast.Program) EvalError!Value {
        var last_value = Value{ .none = {} };
        for (program.expressions) |expressions| {
            last_value = try self.evalExpr(expressions);

            if (self.config.enable_trace)
                try self.results.append(self.allocator, .{ .result = last_value });
        }
        return last_value;
    }
    fn evalExpr(self: *Evaluator, expr: Ast.Expr) EvalError!Value {
        return switch (expr) {
            .literal => |lit| self.evalLiteral(lit),
            .identifier => |iden| try self.evalIdentifier(iden),
            .assignment => |assign| try self.evalAssignment(assign),
            else => return error.ExpressionDontExist,
        };
    }
    fn evalAssignment(self: *Evaluator, assign: Ast.AssignExpr) EvalError!Value {
        if (self.globals.contains(assign.name)) {
            return error.VariableAlreadyDefined;
        }
        const value = try self.evalExpr(assign.value.*);
        try self.globals.put(assign.name, value);
        return value;
    }
    fn evalLiteral(self: *Evaluator, lit: Ast.Literal) Value {
        _ = self;
        return switch (lit) {
            .string => |s| Value{ .string = s },
            .number => |n| Value{ .number = n },
            .boolean => |b| Value{ .boolean = b },
            .none => Value{ .none = {} },
        };
    }
    fn evalIdentifier(self: *Evaluator, name: []const u8) EvalError!Value {
        if (self.globals.get(name)) |value| {
            return value;
        } else {
            return error.UndefinedVariable;
        }
    }

    pub fn get_trace(self: *Evaluator) []EvalResult {
        return self.results.items;
    }
};

// ... your existing Evaluator code ...

// ===== TESTS =====
const testing = std.testing;

test "evaluate literal number" {
    const allocator = testing.allocator;

    var lexer = @import("lexer.zig").Lexer.init("x := 42");
    const tokens = try lexer.tokenize(allocator);
    defer allocator.free(tokens);

    var parser = @import("parser.zig").Parser.init(tokens, allocator);
    const program = try parser.parse();
    defer parser.deinit();

    var evaluator = try Evaluator.init(allocator, .{});
    defer evaluator.deinit();

    const result = try evaluator.evaluate(program);
    try testing.expectEqual(Value{ .number = 42.0 }, result);
}

test "undefined variable error" {
    const allocator = testing.allocator;

    var lexer = @import("lexer.zig").Lexer.init("y := unknown");
    const tokens = try lexer.tokenize(allocator);
    defer allocator.free(tokens);

    var parser = @import("parser.zig").Parser.init(tokens, allocator);
    const program = try parser.parse();
    defer parser.deinit();

    var evaluator = try Evaluator.init(allocator, .{});
    defer evaluator.deinit();

    const result = evaluator.evaluate(program);
    try testing.expectError(error.UndefinedVariable, result);
}

// Add more tests...
