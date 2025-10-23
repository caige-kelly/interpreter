const std = @import("std");
const Expr = @import("ast.zig").Expr;
const Literal = @import("ast.zig").Literal;

const KeywordKV = struct { []const u8, TokenType };

pub const KeywordMap = std.StaticStringMap(TokenType).initComptime([_]KeywordKV{ .{ "tap", .TAP }, .{ "match", .MATCH }, .{ "try", .TRY }, .{ "or", .OR }, .{ "none", .NONE }, .{ "then", .THEN }, .{ "true", .BOOLEAN }, .{ "false", .BOOLEAN } });

pub const Token = struct { type: TokenType, lexeme: []const u8, line: usize, column: usize, literal: ?Literal = null };

pub const TokenType = enum {
    // Literals
    NUMBER,
    STRING,
    BOOLEAN,
    IDENTIFIER,

    // Keywords
    NONE,
    MATCH,
    TRY,
    OR,
    THEN,
    TAP,
    ANY,

    // Operators
    PLUS,
    MINUS,
    STAR,
    SLASH,
    EQUAL,
    COLON_EQUAL, // NEW: :=
    EQUAL_EQUAL,
    BANG_EQUAL,
    LESS,
    LESS_EQUAL,
    GREATER,
    GREATER_EQUAL,
    COLON,
    COMMA,
    DOT,
    ARROW,
    PIPE,
    CARET,
    BANG,
    QUESTION,

    // Delimiters
    LEFT_PAREN,
    RIGHT_PAREN,
    LEFT_BRACKET,
    RIGHT_BRACKET,
    LEFT_BRACE,
    RIGHT_BRACE,

    // Special markers
    AT,
    HASH,
    UNDERSCORE,

    // Indentation and whitespace
    INDENT, // NEW: logical indent increase
    DEDENT, // NEW: logical indent decrease
    NEWLINE,

    // End of file
    EOF,
};
