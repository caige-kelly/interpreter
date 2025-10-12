const std = @import("std");
const Ast = @import("ast.zig");

pub fn converter(expr: *const Ast.Expr, allocator: std.mem.Allocator) !*Ast.Expr {
    switch (expr.*) {
        .pipe => {
            const left_expr = try converter(expr.pipe.left, allocator);
            const right_expr = try converter(expr.pipe.right, allocator);

            if (right_expr.* == .call) {
                const old_args = right_expr.call.args;
                const new_len = old_args.len + 1;
                const args = try allocator.alloc(Ast.Expr, new_len);

                std.mem.copyForwards(Ast.Expr, args[0..old_args.len], old_args);
                args[old_args.len] = left_expr.*;

                const new_call = try allocator.create(Ast.Expr);

                new_call.* = Ast.Expr{
                    .call = .{ .callee = right_expr.call.callee, .args = args },
                };

                return new_call;
            }

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

        else => {
            const copy = try allocator.create(Ast.Expr);
            copy.* = expr.*;
            return copy;
        },
    }
}
