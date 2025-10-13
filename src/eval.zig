const std = @import("std");
const Ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const Context = @import("context.zig").Context;

pub fn eval(ctx: *Context, expr: *Ast.Expr) !Value {
    switch (expr.*) {
        .literal => return evalLiteral(expr.literal),
        .identifier => return evalIdentifier(ctx, expr.identifier),
        .assign => return evalAssign(ctx, expr.assign),
        .match_expr => return evalMatch(ctx, expr),
        .pipe => return evalPipe(ctx, expr.pipe),
        else => Value{ .none = {} },
    }
}

fn evalLiteral(lit: Ast.Literal) Value {
    return switch (lit) {
        .number => |n| Value{ .number = n },
        .string => |s| Value{ .string = s },
        .boolean => |b| Value{ .boolean = b },
        .result => |r| Value{ .result = .{ .tag = r.tag, .value = null } },
        .none => Value{ .none = {} },
        else => Value{ .none = {} },
    };
}

fn evalAssign(ctx: *Context, assign: Ast.Assign) !Value {
    const val = try eval(ctx, assign.value);
    try ctx.set(assign.name, val);
    return val;
}

fn evalIdentifier(ctx: *Context, name: []const u8) !Value {
    if (ctx.get(name)) |val| return val;
    return error.UnknownVariable;
}

fn evalTry(ctx: *Context, expr: *Ast.TryExpr) !Value {
    const val = try eval(ctx, expr.expr);
    if (val != .result) return val;

    switch (val.result.tag) {
        .ok => return val.result.system.*,
        .err => return Value{ .none = {} },
    }
}

fn evalMatch(ctx: *Context, expr: *Ast.Expr) !Value {
    const m = expr.match_expr;
    const val = try eval(ctx, m.value);

    if (val != .result) {
        return error.MatchNonResult; // enforce matching only on Result
    }

    for (m.branches) |branch| {
        if (std.mem.eql(u8, branch.pattern, "ok") and val.result.tag == .ok) {
            if (branch.binding) |name| {
                const bind_val = val.result.system orelse Value{ .none = {} };
                try ctx.set(name, bind_val.*);
            }
            return try eval(ctx, branch.expr);
        }

        if (std.mem.eql(u8, branch.pattern, "err") and val.result.tag == .err) {
            if (branch.binding) |name| {
                const bind_val = val.result.user orelse Value{ .none = {} };
                try ctx.set(name, bind_val.*);
            }
            return try eval(ctx, branch.expr);
        }
    }

    return error.NoMatchFound;
}

fn evalMatchBranch(ctx: *Context, m: Ast.MatchExpr, tag: []const u8, sys: Value) !Value {
    for (m.branches) |b| {
        if (std.mem.eql(u8, b.pattern, tag) or std.mem.eql(u8, b.pattern, "_")) {
            ctx.set("_", sys);
            return try eval(ctx, b.expr);
        }
    }
    return error.NoMatchFound;
}

fn evalPipe(ctx: *Context, pipe: Ast.Pipe) !Value {
    const left_val = try eval(ctx, pipe.left);
    const right_expr = pipe.right;

    switch (right_expr.*) {
        .identifier => |func_name| {
            std.debug.print("Pipe call: {s}({any})\n", .{ func_name, left_val });
            return left_val;
        },
        else => return eval(ctx, right_expr),
    }
}

fn patternMatches(val: Value, pat: []const u8) bool {
    if (std.mem.eql(u8, pat, "_")) return true;
    if (val == .result) {
        if (std.mem.eql(u8, pat, ".ok") and val.result.tag == .ok) return true;
        if (std.mem.eql(u8, pat, ".err") and val.result.tag == .err) return true;
    }
    if (val == .string and std.mem.eql(u8, val.string, pat)) return true;
    if (val == .boolean) {
        if (val.boolean and std.mem.eql(u8, pat, "true")) return true;
        if (!val.boolean and std.mem.eql(u8, pat, "false")) return true;
    }
    return false;
}
