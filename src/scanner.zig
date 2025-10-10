const std = @import("std");
const errors = @import("error.zig");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;

pub const Scanner = struct {
    source: []const u8,
    tokens: std.ArrayList(Token),
    allocator: std.mem.Allocator,
    start: usize = 0,
    current: usize = 0,
    line: usize = 1,
    column: usize = 0,

    pub fn init(source: []const u8, allocator: std.mem.Allocator) !Scanner {
        return Scanner{ .source = source, .allocator = allocator, .tokens = try std.ArrayList(Token).initCapacity(allocator, 4096) };
    }

    pub fn deinit(self: *Scanner) void {
        self.tokens.deinit(self.allocator);
    }

    pub fn scanTokens(self: *Scanner) ![]Token {
        while (!self.isAtEnd()) {
            self.start = self.current;
            const t = self.scanToken();
            if (t != null) try self.makeToken(t.?) else continue;
        }

        try self.endOfFie();
        return self.tokens.items;
    }

    pub fn scanToken(self: *Scanner) ?TokenType {
        const c = self.advance();

        return switch (c) {
            // Single-character tokens
            '(' => .LEFT_PAREN,
            ')' => .RIGHT_PAREN,
            '{' => .LEFT_BRACE,
            '}' => .RIGHT_BRACE,
            ',' => .COMMA,
            '.' => .DOT,
            '-' => .MINUS,
            '+' => .PLUS,
            ';' => .SEMICOLON,
            '*' => .STAR,
            '/' => if (self.match('/')) self.commentLexeme() else .SLASH,
            '!' => if (self.match('=')) .BANG_EQUAL else .BANG,
            '=' => if (self.match('=')) .EQUAL_EQUAL else .EQUAL,
            '<' => if (self.match('=')) .LESS_EQUAL else .LESS,
            '>' => if (self.match('=')) .GREATER_EQUAL else .GREATER,
            ' ' => null,
            '\r' => null,
            '\t' => null,
            '\n' => self.newLineLexeme(),
            else => self.undefinedLexeme(),
        };
    }

    fn newLineLexeme(self: *Scanner) ?TokenType {
        self.column = 0;
        self.line += 1;
        return null;
    }

    fn undefinedLexeme(self: *Scanner) ?TokenType {
        errors.report(self.line, "", "Unexpected character.");
        return null;
    }

    fn commentLexeme(self: *Scanner) ?TokenType {
        while (self.peek() != '\n' and !self.isAtEnd()) {
            _ = self.advance();
        }
        return null;
    }

    fn advance(self: *Scanner) u8 {
        const ch = self.source[self.current];
        self.current += 1;
        self.column += 1;
        return ch;
    }

    fn peek(self: *Scanner) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn isAtEnd(self: *Scanner) bool {
        return self.current >= self.source.len;
    }

    fn endOfFie(self: *Scanner) !void {
        try self.makeToken(.EOF);
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;

        self.current += 1;
        self.column += 1;
        return true;
    }

    fn makeToken(self: *Scanner, t: TokenType) !void {
        const token = Token{
            .type = t,
            .lexeme = self.source[self.start..self.current],
            .literal = "",
            .line = self.line,
            .column = self.column,
        };

        try self.tokens.append(self.allocator, token);
    }
};
