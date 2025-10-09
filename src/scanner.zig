const std = @import("std");
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
        return Scanner{ 
            .source = source, 
            .allocator = allocator, 
            .tokens = try std.ArrayList(Token).initCapacity(allocator, 4096) 
        };
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

    pub fn scanTokens(self: *Scanner) void {
        while (!self.isAtEnd()) {
            self.start = self.current;
            self.scanToken();
        }
    }

    pub fn scanToken(self: *Scanner) Token {
        while (!self.isAtEnd()) {
            const c = self.advance();

            switch (c) {
                // Single-character tokens
                '(' => return self.makeToken(.LEFT_PAREN, 1),
                ')' => return self.makeToken(.RIGHT_PAREN, 1),
                '{' => return self.makeToken(.LEFT_BRACE, 1),
                '}' => return self.makeToken(.RIGHT_BRACE, 1),
                ',' => return self.makeToken(.COMMA, 1),
                '.' => return self.makeToken(.DOT, 1),
                '-' => return self.makeToken(.MINUS, 1),
                '+' => return self.makeToken(.PLUS, 1),
                ';' => return self.makeToken(.SEMICOLON, 1),
                '*' => return self.makeToken(.STAR, 1),
                '/' => return self.makeToken(.SLASH, 1),

                // Multi-character operators
                '!' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return self.makeToken(.BANG_EQUAL, 2);
                    } else {
                        return self.makeToken(.BANG, 1);
                    }
                },
                '=' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return self.makeToken(.EQUAL_EQUAL, 2);
                    } else {
                        return self.makeToken(.EQUAL, 1);
                    }
                },
                '<' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return self.makeToken(.LESS_EQUAL, 2);
                    } else {
                        return self.makeToken(.LESS, 1);
                    }
                },
                '>' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return self.makeToken(.GREATER_EQUAL, 2);
                    } else {
                        return self.makeToken(.GREATER, 1);
                    }
                },

                // Whitespace
                ' ', '\t', '\r' => continue,
                '\n' => {
                    self.line += 1;
                    continue;
                },

                // Unknown letters are ignored for now
                else => continue,
            }
        }

        // End of input
        return Token{ .type = .EOF, .lexeme = "", .literal = "", .line = self.line, .column = self.current };
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
