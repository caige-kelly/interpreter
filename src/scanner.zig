const std = @import("std");
const errors = @import("error.zig");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Literal = @import("token.zig").Literals;

const numbers = [_]u8{ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' };

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
            if (t != null) try self.tokens.append(self.allocator, t.?) else continue;
        }

        try self.tokens.append(self.allocator, self.endOfFie().?);
        return self.tokens.items;
    }

    pub fn scanToken(self: *Scanner) ?Token {
        const c = self.advance();

        return switch (c) {
            // Single-character tokens
            '(' => self.makeToken(.LEFT_PAREN, null),
            ')' => self.makeToken(.RIGHT_PAREN, null),
            '{' => self.makeToken(.LEFT_BRACE, null),
            '}' => self.makeToken(.RIGHT_BRACE, null),
            ',' => self.makeToken(.COMMA, null),
            '.' => self.makeToken(.DOT, null),
            '-' => self.makeToken(.MINUS, null),
            '+' => self.makeToken(.PLUS, null),
            ';' => self.makeToken(.SEMICOLON, null),
            '*' => self.makeToken(.STAR, null),
            '"' => self.makeToken(self.stringLiteral(), .{ .string = self.source[self.start + 1 .. self.current - 1] }),
            '/' => if (self.match('/')) self.commentLexeme() else self.makeToken(.SLASH, null),
            '!' => if (self.match('=')) self.makeToken(.BANG_EQUAL, null) else self.makeToken(.BANG, null),
            '=' => if (self.match('=')) self.makeToken(.EQUAL_EQUAL, null) else self.makeToken(.EQUAL, null),
            '<' => if (self.match('=')) self.makeToken(.LESS_EQUAL, null) else self.makeToken(.LESS, null),
            '>' => if (self.match('=')) self.makeToken(.GREATER_EQUAL, null) else self.makeToken(.GREATER, null),
            ' ' => null,
            '\r' => null,
            '\t' => null,
            '\n' => self.newLineLexeme(),
            else => if (isNumber(c))
                self.makeToken(self.numberLiteral(), .{ .number = std.fmt.parseFloat(f64, self.source[self.start..self.current]) catch unreachable })
            else
                self.undefinedLexeme(),
        };
    }

    fn newLineLexeme(self: *Scanner) ?Token {
        self.column = 0;
        self.line += 1;
        return null;
    }

    fn undefinedLexeme(self: *Scanner) ?Token {
        errors.report(self.line, "", "Unexpected character.");
        return null;
    }

    fn commentLexeme(self: *Scanner) ?Token {
        while (self.peek() != '\n' and !self.isAtEnd()) {
            _ = self.advance();
        }
        return null;
    }

    fn isNumber(token: u8) bool {
        for (numbers) |number| {
            if (token == number) return true;
        }

        return false;
    }

    fn numberLiteral(self: *Scanner) ?TokenType {
        while (isNumber(self.peek())) _ = self.advance();

        if (self.peek() == '.' and isNumber(self.peekNext())) {
            _ = self.advance();
            while (isNumber(self.peek())) _ = self.advance();
        }

        return .NUMBER;
    }

    fn stringLiteral(self: *Scanner) ?TokenType {
        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\n') self.line += 1;
            _ = self.advance();
        }

        if (self.isAtEnd()) {
            errors.report(self.line, "", "Unterminatd string.");
            return null;
        }

        _ = self.advance();

        return .STRING;
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

    fn peekNext(self: *Scanner) u8 {
        if (self.current + 1 >= self.source.len) return '0';
        return self.source[self.current + 1];
    }

    fn isAtEnd(self: *Scanner) bool {
        return self.current >= self.source.len;
    }

    fn endOfFie(self: *Scanner) ?Token {
        return self.makeToken(.EOF, null);
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;

        self.current += 1;
        self.column += 1;
        return true;
    }

    fn makeToken(self: *Scanner, t: ?TokenType, literal: ?Literal) ?Token {
        if (t == null) return null;

        return Token{
            .type = t.?,
            .lexeme = self.source[self.start..self.current],
            .literal = if (literal == null) .{ .string = "" } else literal.?,
            .line = self.line,
            .column = self.column,
        };
    }
};
