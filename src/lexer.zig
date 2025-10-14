const std = @import("std");
const errors = @import("error.zig");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Literal = @import("ast.zig").Literal;
const KeywordMap = @import("token.zig").KeywordMap;

const initial_token_capacity = 4096;

pub const Lexer = struct {
    source: []const u8,
    tokens: std.ArrayList(Token),
    allocator: std.mem.Allocator,

    start: usize = 0,
    current: usize = 0,
    line: usize = 1,
    column: usize = 0,
    start_column: usize = 0,

    pub fn init(source: []const u8, alloc: std.mem.Allocator) !Lexer {
        return .{
            .source = source,
            .allocator = alloc,
            .tokens = try std.ArrayList(Token).initCapacity(alloc, initial_token_capacity),
        };
    }

    pub fn scanTokens(self: *Lexer) ![]Token {
        while (!self.isAtEnd()) {
            self.start = self.current;
            self.start_column = self.column;
            try self.scanToken();
        }

        self.start = self.current;
        self.start_column = self.column;
        try self.makeToken(.EOF, .none);

        return self.tokens.items;
    }

    pub fn scanToken(self: *Lexer) !void {
        const c = self.advance();

        switch (c) {
            '(' => return self.makeToken(.LEFT_PAREN, .none),
            ')' => return self.makeToken(.RIGHT_PAREN, .none),
            '{' => return self.makeToken(.LEFT_BRACE, .none),
            '}' => return self.makeToken(.RIGHT_BRACE, .none),
            '[' => return self.makeToken(.LEFT_BRACKET, .none),
            ']' => return self.makeToken(.RIGHT_BRACKET, .none),
            ',' => return self.makeToken(.COMMA, .none),
            '.' => return self.makeToken(.DOT, .none),
            ':' => return self.makeToken(.COLON, .none),
            '+' => return self.makeToken(.PLUS, .none),
            '-' => {
                if (self.match('>')) return self.makeToken(.ARROW, .none);
                return self.makeToken(.MINUS, .none);
            },
            '*' => return self.makeToken(.STAR, .none),
            '@' => return self.makeToken(.AT, .none),
            '#' => return self.makeToken(.HASH, .none),
            '^' => return self.makeToken(.CARET, .none),
            '|' => return if (self.match('>')) self.makeToken(.PIPE, .none) else self.undefinedLexeme(),
            '"' => {
                const processed = self.stringLiteral();
                return self.makeToken(.STRING, .{ .string = try processed });
            },
            '_' => return self.makeToken(.UNDERSCORE, .none),
            '/' => return if (self.match('/')) self.commentLexeme() else self.makeToken(.SLASH, .none),
            '!' => return if (self.match('=')) self.makeToken(.BANG_EQUAL, .none) else self.makeToken(.BANG, .none),
            '=' => return if (self.match('=')) self.makeToken(.EQUAL_EQUAL, .none) else self.makeToken(.EQUAL, .none),
            '<' => return if (self.match('=')) self.makeToken(.LESS_EQUAL, .none) else self.makeToken(.LESS, .none),
            '>' => return if (self.match('=')) self.makeToken(.GREATER_EQUAL, .none) else self.makeToken(.GREATER, .none),
            ' ' => return,
            '\r' => return,
            '\t' => return,
            '\n' => return try self.newLine(),
            else => if (isNumber(c)) {
                return self.makeToken(self.numberLiteral(), .{ .number = try std.fmt.parseFloat(f64, self.source[self.start..self.current]) });
            } else if (isAlpha(c)) {
                return self.makeToken(self.identifier(), .none);
            } else return self.undefinedLexeme(),
        }
    }

    fn newLine(self: *Lexer) !void {
        self.column = 0;
        self.line += 1;
        try self.makeToken(.NEWLINE, .none);
        return;
    }

    fn undefinedLexeme(self: *Lexer) !void {
        errors.report(self.line, "", "Unexpected character.");
        return error.UnexpectedCharacter;
    }

    fn commentLexeme(self: *Lexer) void {
        while (!self.isAtEnd() and self.peek() != '\n') {
            _ = self.advance();
        }
    }

    fn identifier(self: *Lexer) TokenType {
        while (isAlpha(self.peek()) or isNumber(self.peek())) {
            _ = self.advance();
        }

        const word = self.source[self.start..self.current];
        return KeywordMap.get(word) orelse .IDENTIFIER;
    }

    fn isAlpha(token: u8) bool {
        return std.ascii.isAlphabetic(token) or token == '_';
    }

    fn isNumber(token: u8) bool {
        return std.ascii.isDigit(token);
    }

    fn numberLiteral(self: *Lexer) TokenType {
        while (isNumber(self.peek())) _ = self.advance();

        if (self.peek() == '.' and isNumber(self.peekNext())) {
            _ = self.advance();
            while (isNumber(self.peek())) _ = self.advance();
        }

        return .NUMBER;
    }

    fn stringLiteral(self: *Lexer) ![]u8 {
        var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 0);

        var prev: u8 = 0;

        while (!self.isAtEnd()) {
            const ch = self.advance();

            // stop only on an unescaped quote
            if (ch == '"' and prev != '\\') {
                // found a closing quote, string is complete
                const out = try buffer.toOwnedSlice(self.allocator);
                return out;
            }

            if (ch == '\\') {
                if (self.isAtEnd()) break; // broken escape at EOF
                const next = self.advance();
                const escaped = switch (next) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    else => next, // unknown escapes pass through
                };
                try buffer.append(self.allocator, escaped);
                prev = next;
            } else {
                try buffer.append(self.allocator, ch);
                prev = ch;
            }

            if (ch == '\n') self.line += 1;
        }

        // If we reach here, EOF was hit before a closing quote
        errors.report(self.line, "", "Unterminated string literal (missing closing quote).");
        _ = buffer.deinit(self.allocator);
        return error.UnterminatedString;
    }

    fn advance(self: *Lexer) u8 {
        const ch = self.source[self.current];
        self.current += 1;
        self.column += 1;
        return ch;
    }

    fn peek(self: *Lexer) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn peekNext(self: *Lexer) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.current >= self.source.len;
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;

        self.current += 1;
        self.column += 1;
        return true;
    }

    fn makeToken(self: *Lexer, t: TokenType, literal: Literal) !void {
        var lit = literal;
        switch (t) {
            .TRUE => lit = .{ .boolean = true },
            .FALSE => lit = .{ .boolean = false },
            .NONE => lit = .{ .none = {} }, // empty struct for void
            else => {},
        }

        const token = Token{
            .type = t,
            .lexeme = self.source[self.start..self.current],
            .literal = lit,
            .line = self.line,
            .column = self.start_column,
        };

        try self.tokens.append(self.allocator, token);
    }
};
