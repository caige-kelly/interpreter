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
    target: *Expr,
    ok_param: []const u8,
    ok_body: *Expr,
    err_param: []const u8,
    err_body: *Expr,
};
