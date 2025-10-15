const std = @import("std");
const Expr = @import("ast.zig").Expr;
const Literals = @import("ast.zig").Literal;

pub const KeywordMap = std.StaticStringMap(TokenType).initComptime(.{ .{ "tap", .TAP }, .{ "match", .MATCH }, .{ "try", .TRY }, .{ "or", .OR }, .{ "use", .USE }, .{ "true", .TRUE }, .{ "false", .FALSE }, .{ "none", .NONE }, .{ "and", .AND } });

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

    pub fn getBLiteral(self: Token) ?bool {
        return switch (self.literal) {
            .boolean => |s| s,
            else => null,
        };
    }

    pub fn getVLiteral(self: Token) ?void {
        return switch (self.literal) {
            .none => |s| s,
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
    NEWLINE,
    UNDERSCORE,

    // --- literals ---
    IDENTIFIER,
    STRING,
    NUMBER,
    TRUE,
    FALSE,
    NONE,

    // --- prefixes ---
    AT, // @   monad
    HASH, // #   intrinsic

    // --- keywords ---
    MATCH,
    TRY,
    OR,
    USE,
    AND,
    TAP,

    // --- other ---
    EOF,
};
