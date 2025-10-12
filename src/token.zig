const std = @import("std");
const Expr = @import("ast.zig").Expr;
const Literals = @import("ast.zig").Literal;

pub const KeywordMap = std.StaticStringMap(TokenType).initComptime(.{
    .{ "match", .MATCH },
    .{ "try", .TRY },
    .{ "or", .OR },
    .{ "use", .USE },
});

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    literal: Literals,
    line: usize,
    column: usize,

    pub fn getNLiteral(self: Token) ?f64 {
        return switch (self.literal) {
            .number => |n| n,
            else => null,
        };
    }

    pub fn getSLiteral(self: Token) ?[]const u8 {
        return switch (self.literal) {
            .string => |s| s,
            else => null,
        };
    }
};

pub const TokenType = enum {
    // --- structural symbols ---
    LEFT_PAREN,
    RIGHT_PAREN,
    LEFT_BRACKET,
    RIGHT_BRACKET,
    LEFT_BRACE,
    RIGHT_BRACE,
    COMMA,
    DOT,
    COLON,
    PLUS,
    MINUS,
    STAR,
    SLASH,
    CARET, // ^
    ARROW, // ->
    EQUAL,
    EQUAL_EQUAL,
    BANG,
    BANG_EQUAL,
    GREATER,
    GREATER_EQUAL,
    LESS,
    LESS_EQUAL,
    PIPE,
    ESCAPE,

    // --- literals ---
    IDENTIFIER,
    STRING,
    NUMBER,

    // --- prefixes ---
    AT, // @   monad
    HASH, // #   intrinsic

    // --- keywords ---
    MATCH,
    TRY,
    OR,
    USE,

    // --- other ---
    EOF,
};
