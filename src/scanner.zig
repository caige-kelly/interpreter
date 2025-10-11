const std = @import("std");
const errors = @import("error.zig");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Literal = @import("token.zig").Literals;
const Keywords = @import("token.zig").Keywords;

const array_buf = 4096; // 4 Kib just cause

pub const Scanner = struct {
    source: []const u8,
    tokens: std.ArrayList(Token),
    allocator: std.mem.Allocator,
    start: usize = 0,
    current: usize = 0,
    line: usize = 1,
    column: usize = 0,
    start_column: usize = 0,

    pub fn init(source: []const u8, allocator: std.mem.Allocator) !Scanner {
        return Scanner{ .source = source, .allocator = allocator, .tokens = try std.ArrayList(Token).initCapacity(allocator, array_buf) };
    }

    pub fn deinit(self: *Scanner) void {
        self.tokens.deinit(self.allocator);
    }

    pub fn scanTokens(self: *Scanner) ![]Token {
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

    pub fn scanToken(self: *Scanner) !void {
        const c = self.advance();

        try switch (c) {
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
            '"' => self.makeToken(try self.stringLiteral(), .{ .string = self.source[self.start + 1 .. self.current - 1] }),
            '/' => if (self.match('/')) self.commentLexeme() else self.makeToken(.SLASH, .none),
            '!' => if (self.match('=')) self.makeToken(.BANG_EQUAL, .none) else self.makeToken(.BANG, .none),
            '=' => if (self.match('=')) self.makeToken(.EQUAL_EQUAL, .none) else self.makeToken(.EQUAL, .none),
            '<' => if (self.match('=')) self.makeToken(.LESS_EQUAL, .none) else self.makeToken(.LESS, .none),
            '>' => if (self.match('=')) self.makeToken(.GREATER_EQUAL, .none) else self.makeToken(.GREATER, .none),
            ' ' => return,
            '\r' => return,
            '\t' => return,
            '\n' => self.newLine(),
            else => if (isNumber(c)) {
                try self.makeToken(self.numberLiteral(), .{ .number = try std.fmt.parseFloat(f64, self.source[self.start..self.current]) });
            } else if (isAlpha(c)) {
                try self.makeToken(try self.identifier(), .{ .string = self.source[self.start..self.current] });
            } else self.undefinedLexeme(),
        };
    }

    fn scanKeyword(word: []const u8) !TokenType {
        var buf: [1024]u8 = undefined;
        const keyword: Keywords = std.meta.stringToEnum(Keywords, std.ascii.upperString(&buf, word)) orelse return error.StringToEnum;

        switch (keyword) {
            .AND => return .AND,
            .CLASS => return .CLASS,
            .ELSE => return .ELSE,
            .FALSE => return .FALSE,
            .FUN => return .FUN,
            .FOR => return .FOR,
            .IF => return .IF,
            .NIL => return .NIL,
            .OR => return .OR,
            .PRINT => return .PRINT,
            .RETURN => return .RETURN,
            .SUPER => return .SUPER,
            .THIS => return .THIS,
            .TRUE => return .TRUE,
            .VAR => return .VAR,
            .WHILE => return .WHILE,
        }
    }

    fn newLine(self: *Scanner) void {
        self.column = 0;
        self.line += 1;
        return;
    }

    fn undefinedLexeme(self: *Scanner) !void {
        errors.report(self.line, "", "Unexpected character.");
        return error.UnexpectedCharacter;
    }

    fn commentLexeme(self: *Scanner) void {
        while (!self.isAtEnd() and self.peek() != '\n') {
            _ = self.advance();
        }
        return;
    }

    fn identifier(self: *Scanner) !TokenType {
        while (isAlpha(self.peek()) or isNumber(self.peek())) {
            _ = self.advance();
        }

        return try scanKeyword(self.source[self.start..self.current]);
    }

    fn isAlpha(token: u8) bool {
        return (token >= 'a' and token <= 'z') or (token >= 'A' and token <= 'Z') or (token == '_');
    }

    fn isNumber(token: u8) bool {
        return (token >= '0' and token <= '9');
    }

    fn numberLiteral(self: *Scanner) TokenType {
        while (isNumber(self.peek())) _ = self.advance();

        if (self.peek() == '.' and isNumber(self.peekNext())) {
            _ = self.advance();
            while (isNumber(self.peek())) _ = self.advance();
        }

        return .NUMBER;
    }

    fn stringLiteral(self: *Scanner) !TokenType {
        while (!self.isAtEnd() and self.peek() != '"') {
            if (self.peek() == '\n') self.line += 1;
            _ = self.advance();
        }

        if (self.isAtEnd()) {
            errors.report(self.line, "", "Unterminatd string.");
            return error.UnterminatedString;
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
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn isAtEnd(self: *Scanner) bool {
        return self.current >= self.source.len;
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;

        self.current += 1;
        self.column += 1;
        return true;
    }

    fn makeToken(self: *Scanner, t: TokenType, literal: Literal) !void {
        const token = Token{
            .type = t,
            .lexeme = self.source[self.start..self.current],
            .literal = literal,
            .line = self.line,
            .column = self.start_column,
        };

        try self.tokens.append(self.allocator, token);
    }
};
