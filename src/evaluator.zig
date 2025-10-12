const std = @import("std");
const Ast = @import("ast.zig");

pub fn converter(expr: *const Ast.Expr, allocator: std.mem.Allocator) !*Ast.Expr {
    // Recursively convert inner nodes firt
    switch (expr.*) {
        .pipe => {
            const left_expr = try converter(expr.pipe.left, allocator);
            const right_expr = try converter(expr.pipe.right, allocator);

            const args_slice = try allocator.alloc(Ast.Expr, 1);
            args_slice[0] = left_expr.*;

            const call_node = try allocator.create(Ast.Expr);
            call_node.* = Ast.Expr{ .call = .{ .callee = right_expr, .args = args_slice } };

            return call_node;
        },
        .call => {
            const callee = try converter(expr.call.callee, allocator);
            var args = try allocator.alloc(Ast.Expr, expr.call.args.len);
            for (args, 0..) |*arg, i| {
                const darg = try converter(arg, allocator);
                args[i] = darg.*;
            }

            const new_expr = try allocator.create(Ast.Expr);
            new_expr.* = Ast.Expr{ .call = .{ .callee = callee, .args = args } };
            return new_expr;
        },
        else => {
            const copy = try allocator.create(Ast.Expr);
            copy.* = expr.*;
            return copy;
        },
    }
}
