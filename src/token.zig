// All things related to tokens
pub const Literals = union(enum) { number: f64, string: []const u8, none: void };

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

pub const TokenType = enum(u8) {
    // Single-character tokens.
    LEFT_PAREN,
    RIGHT_PAREN,
    LEFT_BRACE,
    RIGHT_BRACE,
    COMMA,
    DOT,
    MINUS,
    PLUS,
    SEMICOLON,
    SLASH,
    STAR,

    // One or two character tokens.
    BANG,
    BANG_EQUAL,
    EQUAL,
    EQUAL_EQUAL,
    GREATER,
    GREATER_EQUAL,
    LESS,
    LESS_EQUAL,

    // Literals
    IDENTIFIER,
    STRING,
    NUMBER,

    // Keywords.
    AND,
    CLASS,
    ELSE,
    FALSE,
    FUN,
    FOR,
    IF,
    NIL,
    OR,
    PRINT,
    RETURN,
    SUPER,
    THIS,
    TRUE,
    VAR,
    WHILE,

    EOF,
};
