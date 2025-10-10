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

    pub fn init(source: []const u8, allocator: std.mem.Allocator) !Scanner {
        return Scanner{ .source = source, .allocator = allocator, .tokens = try std.ArrayList(Token).initCapacity(allocator, 4096) };
    }

    pub fn deinit(self: *Scanner) void {
        self.tokens.deinit(self.allocator);
    }

    pub fn isAtEnd(self: *Scanner) bool {
        return self.current >= self.source.len;
    }

    pub fn advance(self: *Scanner) u8 {
        const ch = self.source[self.current];
        self.current += 1;
        return ch;
    }

    pub fn peek(self: *Scanner) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    pub fn scanTokens(self: *Scanner) !void {
        while (!self.isAtEnd()) {
            self.start = self.current;
            try self.scanToken();
        }
        try self.tokens.append(self.allocator, self.makeToken(.EOF, 1));
    }

    pub fn scanToken(self: *Scanner) !void {
        const c = self.advance();

        const token = switch (c) {
            // Single-character tokens
            '(' => self.makeToken(.LEFT_PAREN, 1),
            ')' => self.makeToken(.RIGHT_PAREN, 1),
            '{' => self.makeToken(.LEFT_BRACE, 1),
            '}' => self.makeToken(.RIGHT_BRACE, 1),
            ',' => self.makeToken(.COMMA, 1),
            '.' => self.makeToken(.DOT, 1),
            '-' => self.makeToken(.MINUS, 1),
            '+' => self.makeToken(.PLUS, 1),
            ';' => self.makeToken(.SEMICOLON, 1),
            '*' => self.makeToken(.STAR, 1),
            '/' => self.makeToken(.SLASH, 1),
            ' ', '\t', '\r' => return,
            '\n' => {
                self.line += 1;
                return;
            },
            else => {
                try errors.report(self.line, "", "Unexpected character.");
                return;
            },
        };
        try self.tokens.append(self.allocator, token);
    }

    fn makeToken(self: *Scanner, t: TokenType, length: usize) Token {
        const start = self.current - length;
        return Token{
            .type = t,
            .lexeme = self.source[start..self.current],
            .literal = "",
            .line = self.line,
            .column = start,
        };
    }
};
