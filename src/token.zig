const std = @import("std");
const Expr = @import("ast.zig").Expr;
const Literal = @import("types.zig").Literal;

pub const KeywordMap = std.StaticStringMap(TokenType).initComptime(.{ .{ "tap", .TAP }, .{ "match", .MATCH }, .{ "try", .TRY }, .{ "or", .OR }, .{ "use", .USE }, .{ "true", .TRUE }, .{ "false", .FALSE }, .{ "none", .NONE }, .{ "and", .AND } });

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: usize,
    column: usize,
    literal: ?Literal = null,

    pub fn getNLiteral(self: Token) ?f64 {
        if (self.literal) |lit| {
            if (lit == .number) return lit.number;
        }
        return null;
    }

    pub fn getSLiteral(self: Token) ?[]const u8 {
        if (self.literal) |lit| {
            if (lit == .string) return lit.string;
        }
        return null;
    }
};

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
