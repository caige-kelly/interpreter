const std = @import("std");

// -------------------------------
// Expression node definitions
// -------------------------------

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

fn indent(depth: usize) void {
    // print two spaces per depth; no buffers, no aliasing
    for (0..depth) |_| std.debug.print("  ", .{});
}

pub fn debugPrint(expr: Expr, depth: usize) void {
    switch (expr) {
        .literal => |lit| switch (lit) {
            .number => {
                indent(depth);
                std.debug.print("Number: {}\n", .{lit.number});
            },
            .string => {
                indent(depth);
                std.debug.print("String: \"{s}\"\n", .{lit.string});
            },
            .boolean => {
                indent(depth);
                std.debug.print("Bool: {}\n", .{lit.boolean});
            },
            .none => {
                indent(depth);
                std.debug.print("None\n", .{});
            },
            .list => |items| {
                indent(depth);
                std.debug.print("List:\n", .{});
                for (items) |item| {
                    indent(depth + 1);
                    switch (item) {
                        .literal => switch (item.literal)  {
                            .boolean => std.debug.print("item: {}\n", .{item.literal.boolean}),
                            .string => std.debug.print("item: {s}\n", .{item.literal.string}),
                            .number => std.debug.print("item: {d}\n", .{item.literal.number}),
                            .none => std.debug.print("item: {}\n", .{item.literal.none}),
                            else => {},
                        },
                        .identifier => switch(item) {
                            else => std.debug.print("item: {s}\n", .{item.identifier})
                        },
                        else => {},
                    }
                }
            },
            else => {
                indent(depth);
                std.debug.print("Literal (complex)\n", .{});
            },
        },

        .identifier => {
            indent(depth);
            std.debug.print("Identifier: {s}\n", .{expr.identifier});
        },

        .call => {
            indent(depth);
            std.debug.print("Call\n", .{});
            indent(depth);
            std.debug.print("├── callee\n", .{});
            debugPrint(expr.call.callee.*, depth + 1);

            if (expr.call.args.len > 0) {
                indent(depth);
                std.debug.print("└── args\n", .{});
                for (expr.call.args, 0..) |arg, i| {
                    indent(depth + 1);
                    const is_last = (i == expr.call.args.len - 1);
                    std.debug.print("{s} arg[{d}]:\n", .{ if (is_last) "└──" else "├──", i });
                    debugPrint(arg, depth + 2);
                }
            }
        },

        .pipe => {
            indent(depth);
            std.debug.print("Pipe\n", .{});
            indent(depth);
            std.debug.print("├── left\n", .{});
            debugPrint(expr.pipe.left.*, depth + 1);
            indent(depth);
            std.debug.print("└── right\n", .{});
            debugPrint(expr.pipe.right.*, depth + 1);
        },

        .try_expr => {
            indent(depth);
            std.debug.print("Try\n", .{});
            indent(depth);
            std.debug.print("└── expr\n", .{});
            debugPrint(expr.try_expr.expr.*, depth + 1);
        },

        .assign => |a| {
            indent(depth);
            std.debug.print("Assign:\n", .{});
            indent(depth + 1);
            std.debug.print("name: {s}\n", .{a.name});
            indent(depth + 1);
            std.debug.print("value:\n", .{});
            debugPrint(a.value.*, depth + 2);
        },

        .match_expr => |a| {
            indent(depth);
            std.debug.print("Map:\n", .{});
            indent(depth + 1);
            std.debug.print("name: {any}\n", .{a.branches});
            indent(depth + 1);
            std.debug.print("value:\n", .{});
            debugPrint(a.value.*, depth + 2);
        },

        else => {
            indent(depth);
            std.debug.print("(Unhandled node)\n", .{});
        },
    }
}
