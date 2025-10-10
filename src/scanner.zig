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

    pub fn scanTokens(self: *Scanner) !void {
        while (!self.isAtEnd()) {
            self.start = self.current;
            try self.scanToken();
        }

        try self.makeToken(.EOF);
    }

    pub fn scanToken(self: *Scanner) !void {
        const c = self.advance();

        switch (c) {
            // Single-character tokens
            '(' => try self.makeToken(.LEFT_PAREN),
            ')' => try self.makeToken(.RIGHT_PAREN),
            '{' => try self.makeToken(.LEFT_BRACE),
            '}' => try self.makeToken(.RIGHT_BRACE),
            ',' => try self.makeToken(.COMMA),
            '.' => try self.makeToken(.DOT),
            '-' => try self.makeToken(.MINUS),
            '+' => try self.makeToken(.PLUS),
            ';' => try self.makeToken(.SEMICOLON),
            '*' => try self.makeToken(.STAR),
            '!' => if (self.match('=')) try self.makeToken(.BANG_EQUAL) else try self.makeToken(.BANG),
            '=' => if (self.match('=')) try self.makeToken(.EQUAL_EQUAL) else try self.makeToken(.EQUAL),
            '<' => if (self.match('=')) try self.makeToken(.LESS_EQUAL) else try self.makeToken(.LESS),
            '>' => if (self.match('=')) try self.makeToken(.GREATER_EQUAL) else try self.makeToken(.GREATER),
            '/' => if (self.match('/')) {
                while (self.peek() != '\n' and !self.isAtEnd()) {
                    _ = self.advance();
                }
                self.start = self.current;
                return;
            } else {
                try self.makeToken(.SLASH);
            },
            ' ', '\t', '\r' => return,
            '\n' => {
                self.line += 1;
                return;
            },
            else => {
                try errors.report(self.line, "", "Unexpected character.");
                return;
            },
        }
    }

    fn isAtEnd(self: *Scanner) bool {
        return self.current >= self.source.len;
    }

    fn advance(self: *Scanner) u8 {
        const ch = self.source[self.current];
        self.current += 1;
        return ch;
    }

    fn peek(self: *Scanner) ?u8 {
        if (self.isAtEnd()) return null;
        return self.source[self.current];
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;

        self.current += 1;
        return true;
    }

    fn makeToken(self: *Scanner, t: TokenType) !void {
        const token = Token{
            .type = t,
            .lexeme = self.source[self.start..self.current],
            .literal = "",
            .line = self.line,
            .column = self.current,
        };

        try self.tokens.append(self.allocator, token);
    }
};
