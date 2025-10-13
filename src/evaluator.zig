const std = @import("std");
const Ast = @import("ast.zig");

pub fn converter(expr: *const Ast.Expr, allocator: std.mem.Allocator) !*Ast.Expr {
    switch (expr.*) {
        .pipe => {
            const left_expr = try converter(expr.pipe.left, allocator);
            const right_expr = try converter(expr.pipe.right, allocator);

            const args_slice = try allocator.alloc(Ast.Expr, 1);
            args_slice[0] = left_expr.*;

            const call_node = try allocator.create(Ast.Expr);
            call_node.* = Ast.Expr{
                .call = .{
                    .callee = right_expr,
                    .args = args_slice,
                },
            };
            return call_node;
        },

        .call => {
            const callee = try converter(expr.call.callee, allocator);
            const args = try allocator.alloc(Ast.Expr, expr.call.args.len);

            for (expr.call.args, 0..) |*arg, i| {
                const darg = try converter(arg, allocator);
                args[i] = darg.*;
            }

            const new_expr = try allocator.create(Ast.Expr);
            new_expr.* = Ast.Expr{
                .call = .{
                    .callee = callee,
                    .args = args,
                },
            };
            return new_expr;
        },
        .match_expr => return try evalMatch(ctx, expr),

        else => {
            const copy = try allocator.create(Ast.Expr);
            copy.* = expr.*;
            return copy;
        },
    }
}

fn evalMatch(ctx: *Context, expr: *Ast.Expr) !Value {
    const m = expr.match_expr;
    const targetVal = try eval(ctx, m.value);

    for (m.branches) |branch| {
        if (patternMatches(targetVal, branch.pattern)) {
            return eval(ctx, branch.expr);
        }
    }

    return error.NoMatchFound;
}

fn patternMatches(value: Value, pattern: []const u8) bool {
    // Basic literal and tag matching
    if (std.mem.eql(u8, pattern, "_")) return true;

    // Match .ok/.err to Result variants
    if (std.mem.eql(u8, pattern, ".ok") and value == .result and value.result.tag == .ok)
        return true;
    if (std.mem.eql(u8, pattern, ".err") and value == .result and value.result.tag == .err)
        return true;

    // Compare string literal or identifier directly
    if (value == .string and std.mem.eql(u8, pattern, value.string)) return true;
    if (value == .boolean and ((value.boolean and std.mem.eql(u8, pattern, "true")) or
        (!value.boolean and std.mem.eql(u8, pattern, "false"))))
        return true;

    return false;
}
