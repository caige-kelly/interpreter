const std = @import("std");

const TokenType = @import("token.zig").TokenType;

pub const Literal = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    list: []Expr,
    map: []KeyValue,
    result: ResultLiteral,
    none: void,
};

pub const ResultLiteral = struct {
    tag: ResultTag,
    value: ?*Expr, // could be null if just `.ok` or `.err`
};

pub const ResultTag = enum {
    ok,
    err,
};

pub const KeyValue = struct {
    key: []const u8,
    value: *Expr,
};

pub const Expr = union(enum) {
    literal: Literal,
    identifier: []const u8,
    binary: Binary,
    call: Call,
    lambda: Lambda,
    assign: Assign,
    pipe: Pipe,
    try_expr: TryExpr,
    match_expr: MatchExpr,
};

pub const Binary = struct {
    left: *Expr,
    operator: TokenType, // e.g. .PLUS, .OR
    right: *Expr,
};

pub const Call = struct {
    callee: *Expr, // e.g. @File.read
    args: []Expr,
};

pub const Lambda = struct {
    param: []const u8,
    body: *Expr,
};

pub const Assign = struct {
    name: []const u8,
    value: *Expr,
};

pub const Pipe = struct {
    left: *Expr,
    right: *Expr,
};

pub const TryExpr = struct {
    expr: *Expr,
};

pub const MatchExpr = struct {
    value: *Expr,
    branches: []MatchBranch,
};

pub const MatchBranch = struct {
    pattern: []const u8,
    binding: ?[]const u8,
    expr: *Expr,
};

pub fn debugPrint(expr: Expr, depth: usize) void {
    const prefix = makePrefix(depth);

    switch (expr) {
        .literal => |lit| switch (lit) {
            .number => std.debug.print("{s}Number: {}\n", .{ prefix, lit.number }),
            .string => std.debug.print("{s}String: \"{s}\"\n", .{ prefix, lit.string }),
            .boolean => std.debug.print("{s}Bool: {}\n", .{ prefix, lit.boolean }),
            .none => std.debug.print("{s}None\n", .{prefix}),
            else => std.debug.print("{s}Literal (complex)\n", .{prefix}),
        },
        .identifier => std.debug.print("{s} Identifier: {s}\n", .{ prefix, expr.identifier }),

        .call => {
            std.debug.print("{s}Call\n", .{prefix});
            printBranch(depth, "callee");
            debugPrint(expr.call.callee.*, depth + 1);
            if (expr.call.args.len > 0) {
                printBranch(depth, "args");
                for (expr.call.args, 0..) |arg, i| {
                    const connector = if (i == expr.call.args.len - 1) "└──" else "├──";
                    std.debug.print("{s}{s} arg[{d}]:\n", .{ makePrefix(depth + 1), connector, i });
                    debugPrint(arg, depth + 2);
                }
            }
        },

        .pipe => {
            std.debug.print("{s}Pipe\n", .{prefix});
            printBranch(depth, "left");
            debugPrint(expr.pipe.left.*, depth + 1);
            printBranch(depth, "right");
            debugPrint(expr.pipe.right.*, depth + 1);
        },

        .try_expr => {
            std.debug.print("{s}Try\n", .{prefix});
            printBranch(depth, "expr");
            debugPrint(expr.try_expr.expr.*, depth + 1);
        },

        else => std.debug.print("{s}(Unhandled node)\n", .{prefix}),
    }
}

fn makePrefix(depth: usize) []const u8 {
    return switch (depth) {
        0 => "",
        1 => "│ ",
        else => {
            var buf: [128]u8 = undefined;
            const n = @min(buf.len, depth * 2);
            @memset(buf[0..n], ' ');
            return &buf;
        },
    };
}

fn printBranch(depth: usize, label: []const u8) void {
    std.debug.print("{s}├── {s}\n", .{ makePrefix(depth), label });
}
