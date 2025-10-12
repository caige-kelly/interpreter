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

pub fn debugPrint(expr: Expr, depth: usize) !void {
    var indent_buf: [64]u8 = undefined; // supports up to 32 levels (2 spaces each)
    const indent = indent_buf[0..@min(depth * 2, indent_buf.len)];

    @memset(indent, ' ');

    switch (expr) {
        .literal => |lit| {
            switch (lit) {
                .number => std.debug.print("{s}Literal: {d}\n", .{ indent, lit.number }),
                .string => std.debug.print("{s}Literal: \"{s}\"\n", .{ indent, lit.string }),
                .boolean => std.debug.print("{s}Bool: {}\n", .{ indent, lit.boolean }),
                .none => std.debug.print("{s}None: {}\n", .{ indent, lit.none }),
                else => std.debug.print("{s}Literal: (complex)\n", .{indent}),
            }
        },
        .identifier => std.debug.print("{s}Identifier: {s}\n", .{ indent, expr.identifier }),
        .pipe => {
            std.debug.print("{s}Pipe:\n", .{indent});
            try debugPrint(expr.pipe.left.*, depth + 1);
            try debugPrint(expr.pipe.right.*, depth + 1);
        },
        .try_expr => {
            std.debug.print("{s}Try:\n", .{indent});
            try debugPrint(expr.try_expr.expr.*, depth + 1);
        },
        .call => {
            std.debug.print("{s}Call:\n", .{indent});
            try debugPrint(expr.call.callee.*, depth + 1);
            for (expr.call.args) |arg| try debugPrint(arg, depth + 1);
        },
        else => std.debug.print("{s}Expr (unimplemented)\n", .{indent}),
    }
}
