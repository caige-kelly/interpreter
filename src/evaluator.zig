// evalAssignment(assign):
//     1. Check if assign.name exists in globals
//     2. If exists: return error.VariableAlreadyDefined
//     3. Evaluate assign.value by calling evalExpr(assign.value)
//     4. Store assign.name -> result in globals
//     5. Return the result

// // First expression: x := 10
// evalExpr(Expr.assignment { name: "x", value: Expr.literal(10) }):
//     → hits the .assignment case
//     → calls evalAssignment(AssignExpr { name: "x", value: Expr.literal(10) })
//         1. Check globals: "x" doesn't exist ✓
//         2. Evaluate RHS: evalExpr(Expr.literal(10))
//             → hits the .literal case
//             → calls evalLiteral(Literal.number(10))
//                 → returns Value.number(10)
//         3. Store: globals["x"] = Value.number(10)
//         4. Return Value.number(10)

// // Second expression: y := x
// evalExpr(Expr.assignment { name: "y", value: Expr.identifier("x") }):
//     → hits the .assignment case
//     → calls evalAssignment(AssignExpr { name: "y", value: Expr.identifier("x") })
//         1. Check globals: "y" doesn't exist ✓
//         2. Evaluate RHS: evalExpr(Expr.identifier("x"))
//             → hits the .identifier case
//             → calls evalIdentifier("x")
//                 1. Look up "x" in globals
//                 2. Found! Value.number(10)
//                 → returns Value.number(10)
//         3. Store: globals["y"] = Value.number(10)
//         4. Return Value.number(10)

// return Value.number(10)  // Last expression's value
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
