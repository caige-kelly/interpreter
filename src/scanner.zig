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

    // pub fn peek(self: *Scanner) u8 {
    //     if (self.isAtEnd()) return 0;
    //     return self.source[self.current];
    // }

    pub fn scanTokens(self: *Scanner) !void {
        while (!self.isAtEnd()) {
            self.start = self.current;
            try self.scanToken();
        }
        try self.tokens.append(self.allocator, self.makeToken(.EOF));
    }

    pub fn scanToken(self: *Scanner) !void {
        const c = self.advance();

        const token = switch (c) {
            // Single-character tokens
            '(' => self.makeToken(.LEFT_PAREN),
            ')' => self.makeToken(.RIGHT_PAREN),
            '{' => self.makeToken(.LEFT_BRACE),
            '}' => self.makeToken(.RIGHT_BRACE),
            ',' => self.makeToken(.COMMA),
            '.' => self.makeToken(.DOT),
            '-' => self.makeToken(.MINUS),
            '+' => self.makeToken(.PLUS),
            ';' => self.makeToken(.SEMICOLON),
            '*' => self.makeToken(.STAR),
            '/' => self.makeToken(.SLASH),
            '!' => if (self.match('=')) self.makeToken(.BANG_EQUAL) else self.makeToken(.BANG),
            '=' => if (self.match('=')) self.makeToken(.EQUAL_EQUAL) else self.makeToken(.EQUAL),
            '<' => if (self.match('=')) self.makeToken(.LESS_EQUAL) else self.makeToken(.LESS),
            '>' => if (self.match('=')) self.makeToken(.GREATER_EQUAL) else self.makeToken(.GREATER),
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

    fn match(self: *Scanner, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;

        self.current += 1;
        return true;
    }

    fn makeToken(self: *Scanner, t: TokenType) Token {
        return Token{
            .type = t,
            .lexeme = self.source[self.start..self.current],
            .literal = "",
            .line = self.line,
            .column = self.current,
        };
    }
};
