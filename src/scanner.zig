const std = @import("std");
const errors = @import("error.zig");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Literal = @import("token.zig").Literals;

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
            '(' => self.makeToken(.LEFT_PAREN, .none),
            ')' => self.makeToken(.RIGHT_PAREN, .none),
            '{' => self.makeToken(.LEFT_BRACE, .none),
            '}' => self.makeToken(.RIGHT_BRACE, .none),
            ',' => self.makeToken(.COMMA, .none),
            '.' => self.makeToken(.DOT, .none),
            '-' => self.makeToken(.MINUS, .none),
            '+' => self.makeToken(.PLUS, .none),
            ';' => self.makeToken(.SEMICOLON, .none),
            '*' => self.makeToken(.STAR, .none),
            '"' => self.makeToken(self.stringLiteral(), .string),
            '/' => if (self.match('/')) self.commentLexeme() else self.makeToken(.SLASH, .none),
            '!' => if (self.match('=')) self.makeToken(.BANG_EQUAL, .none) else self.makeToken(.BANG, .none),
            '=' => if (self.match('=')) self.makeToken(.EQUAL_EQUAL, .none) else self.makeToken(.EQUAL, .none),
            '<' => if (self.match('=')) self.makeToken(.LESS_EQUAL, .none) else self.makeToken(.LESS, .none),
            '>' => if (self.match('=')) self.makeToken(.GREATER_EQUAL, .none) else self.makeToken(.GREATER, .none),
            ' ' => null,
            '\r' => null,
            '\t' => null,
            '\n' => self.newLineLexeme(),
            else => if (isNumber(c)) self.makeToken(self.numberLiteral(), .number) else if (isAlpha(c)) self.makeToken(self.identifier(), .keyword) else self.undefinedLexeme(),
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

    fn identifier(self: *Scanner) TokenType {
        while (isAlpha(self.peek()) or isNumber(self.peek())) {
            _ = self.advance();
        }

        return .IDENTIFIER;
    }

    fn isAlpha(token: anytype) bool {
        if (token >= 'a' and token <= 'z') return true;
        if (token >= 'A' and token <= 'Z') return true;
        if (token == '_') return true;

        return false;
    }

    fn isNumber(token: anytype) bool {
        if (token >= '0' and token <= '9') {
            return true;
        } else {
            return false;
        }
    }

    fn numberLiteral(self: *Scanner) TokenType {
        while (isNumber(self.peek())) _ = self.advance();

        if (self.peek() == '.' and isNumber(self.peekNext())) {
            _ = self.advance();
            while (isNumber(self.peek())) _ = self.advance();
        }

        return .NUMBER;
    }

    fn stringLiteral(self: *Scanner) TokenType {
        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\n') self.line += 1;
            _ = self.advance();
        }

        if (self.isAtEnd()) {
            errors.report(self.line, "", "Unterminatd string.");
            std.process.exit(1);
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
        //self.start = self.current;
        return self.makeToken(.EOF, .none);
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;

        self.current += 1;
        self.column += 1;
        return true;
    }

    fn makeToken(self: *Scanner, t: TokenType, L: anytype) ?Token {
        const literal = switch (L) {
            .number => Literal{ .number = std.fmt.parseFloat(f64, self.source[self.start..self.current]) catch unreachable },
            .string => Literal{ .string = self.source[self.start + 1 .. self.current - 1] },
            .keyword => Literal{ .string = self.source[self.start..self.current] },
            .none => .none,
            else => .none,
        };

        return Token{
            .type = t,
            .lexeme = self.source[self.start..self.current],
            .literal = literal,
            .line = self.line,
            .column = self.column,
        };

        try self.tokens.append(self.allocator, token);
    }
};
