const std = @import("std");
const errors = @import("error.zig");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Literal = @import("ast.zig").Literal;
const KeywordMap = @import("token.zig").KeywordMap;

const LexState = struct {
    source: []const u8,
    start: usize = 0,
    current: usize = 0,
    line: usize = 1,
    column: usize = 0,
    start_column: usize = 0,
    at_line_start: bool = true,

    fn peek(self: *const LexState) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn peekNext(self: *const LexState) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn isAtEnd(self: *const LexState) bool {
        return self.current >= self.source.len;
    }

    fn advance(self: *LexState) u8 {
        const ch = self.source[self.current];
        self.current += 1;
        self.column += 1;
        return ch;
    }

    fn match(self: *LexState, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;
        self.current += 1;
        self.column += 1;
        return true;
    }
};

pub fn tokenize(source: []const u8, allocator: std.mem.Allocator) ![]Token {
    var tokens = try std.ArrayList(Token).initCapacity(allocator, 64);
    defer tokens.deinit(allocator);

    var state = LexState{ .source = source };

    var indent_stack = try std.ArrayList(usize).initCapacity(allocator, 8);
    defer indent_stack.deinit(allocator);

    while (!state.isAtEnd()) {
        try scanToken(&state, &tokens, &indent_stack, allocator);
    }

    // Close any remaining indents at EOF
    while (indent_stack.items.len > 0) {
        _ = indent_stack.pop();
        try tokens.append(allocator, .{
            .type = .DEDENT,
            .lexeme = "",
            .line = state.line,
            .column = state.column,
            .literal = null,
        });
    }

    try tokens.append(allocator, Token{
        .type = .EOF,
        .lexeme = "",
        .line = state.line,
        .column = state.column,
    });

    const raw_tokens = try tokens.toOwnedSlice(allocator);
    defer allocator.free(raw_tokens);

    const final_tokens = try convertToBlocks(raw_tokens, allocator);
    return final_tokens;
}

pub fn freeTokens(tokens: []Token, allocator: std.mem.Allocator) void {
    for (tokens) |token| {
        if (token.type == .STRING) {
            if (token.literal) |lit| {
                if (lit == .string) {
                    allocator.free(lit.string);
                }
            }
        }
    }
    allocator.free(tokens);
}

fn convertToBlocks(tokens: []Token, allocator: std.mem.Allocator) ![]Token {
    var result = try std.ArrayList(Token).initCapacity(allocator, tokens.len);
    defer result.deinit(allocator);

    var indent_stack = try std.ArrayList(usize).initCapacity(allocator, 8);
    defer indent_stack.deinit(allocator);

    var i: usize = 0;
    while (i < tokens.len) {
        const token = tokens[i];

        switch (token.type) {
            .NEWLINE => {
                const prev_type = if (result.items.len > 0)
                    result.items[result.items.len - 1].type
                else
                    TokenType.EOF;

                const has_indent = i + 1 < tokens.len and tokens[i + 1].type == .INDENT;

                if (has_indent) {
                    const indent_token = tokens[i + 1];
                    const current_indent: usize = @intFromFloat(indent_token.literal.?.number);
                    const after_indent = if (i + 2 < tokens.len) tokens[i + 2].type else TokenType.EOF;

                    // Check if this indent is in a valid context
                    const valid_indent_context = prev_type == .COLON_EQUAL or
                        prev_type == .COLON or
                        prev_type == .EQUAL or
                        prev_type == .ARROW or
                        prev_type == .PIPE or
                        prev_type == .PLUS or
                        prev_type == .MINUS or
                        prev_type == .STAR or
                        prev_type == .SLASH or
                        prev_type == .DOT or
                        after_indent == .PIPE or
                        after_indent == .PLUS or
                        after_indent == .MINUS or
                        after_indent == .STAR or
                        after_indent == .SLASH or
                        after_indent == .DOT;

                    if (!valid_indent_context and indent_stack.items.len == 0) {
                        // Orphan indent - not in a block and no valid continuation
                        return error.UnexpectedIndentation;
                    }

                    if (prev_type == .COLON_EQUAL or prev_type == .COLON or prev_type == .EQUAL) {
                        i += 2;
                        continue;
                    } else if (prev_type == .ARROW) {
                        try result.append(allocator, .{
                            .type = .BLOCK_START,
                            .lexeme = "",
                            .line = token.line,
                            .column = token.column,
                            .literal = null,
                        });
                        try indent_stack.append(allocator, current_indent);
                        i += 2;
                        continue;
                    } else if (valid_indent_context) {
                        i += 2;
                        continue;
                    } else {
                        return error.UnexpectedIndentation;
                    }
                } else {
                    const next_type = if (i + 1 < tokens.len) tokens[i + 1].type else TokenType.EOF;

                    if (next_type == .PIPE or next_type == .PLUS or
                        next_type == .MINUS or next_type == .STAR or
                        next_type == .SLASH or next_type == .DOT)
                    {
                        i += 1;
                        continue;
                    }

                    try result.append(allocator, token);
                    i += 1;
                }
            },
            .DEDENT => {
                if (indent_stack.items.len > 0) {
                    try result.append(allocator, .{
                        .type = .BLOCK_END,
                        .lexeme = "",
                        .line = token.line,
                        .column = token.column,
                        .literal = null,
                    });
                    _ = indent_stack.pop();
                }
                i += 1;
            },
            .INDENT => {
                // Standalone INDENT should have been handled by NEWLINE
                // If we get here, something's wrong
                i += 1;
            },
            else => {
                try result.append(allocator, token);
                i += 1;
            },
        }
    }

    while (indent_stack.items.len > 0) {
        try result.append(allocator, .{
            .type = .BLOCK_END,
            .lexeme = "",
            .line = if (result.items.len > 0) result.items[result.items.len - 1].line else 1,
            .column = if (result.items.len > 0) result.items[result.items.len - 1].column else 1,
            .literal = null,
        });
        _ = indent_stack.pop();
    }

    return try result.toOwnedSlice(allocator);
}

fn handleIndentation(
    state: *LexState,
    tokens: *std.ArrayList(Token),
    indent_stack: *std.ArrayList(usize),
    allocator: std.mem.Allocator,
) !void {
    if (!state.at_line_start) return;
    state.at_line_start = false;

    var spaces: usize = 0;
    while (!state.isAtEnd() and state.peek() == ' ') {
        spaces += 1;
        _ = state.advance();
    }

    if (state.isAtEnd() or state.peek() == '\n') return;

    const current_indent = if (indent_stack.items.len > 0)
        indent_stack.items[indent_stack.items.len - 1]
    else
        0;

    if (spaces > current_indent) {
        try indent_stack.append(allocator, spaces);
        try tokens.append(allocator, .{
            .type = .INDENT,
            .lexeme = "",
            .line = state.line,
            .column = state.start_column,
            .literal = .{ .number = @as(f64, @floatFromInt(spaces)) },
        });
    } else if (spaces < current_indent) {
        while (indent_stack.items.len > 0 and indent_stack.items[indent_stack.items.len - 1] > spaces) {
            _ = indent_stack.pop();
            try tokens.append(allocator, .{
                .type = .DEDENT,
                .lexeme = "",
                .line = state.line,
                .column = state.start_column,
                .literal = .{ .number = @as(f64, @floatFromInt(spaces)) },
            });
        }
    }
}

fn scanToken(
    state: *LexState,
    tokens: *std.ArrayList(Token),
    indent_stack: *std.ArrayList(usize),
    allocator: std.mem.Allocator,
) !void {
    // Handle indentation at the start of each line
    if (state.at_line_start and !state.isAtEnd() and state.peek() != '\n') {
        try handleIndentation(state, tokens, indent_stack, allocator);
    }

    // Set start AFTER handleIndentation so we don't include consumed spaces in lexeme
    state.start = state.current;
    state.start_column = state.column;

    const c = state.advance();

    switch (c) {
        ' ', '\r', '\t' => return,
        '\n' => {
            try tokens.append(allocator, .{
                .type = .NEWLINE,
                .lexeme = "",
                .line = state.line,
                .column = state.start_column,
            });
            state.line += 1;
            state.column = 0;
            state.at_line_start = true;
        },
        '(' => try makeToken(state, tokens, allocator, .LEFT_PAREN, .{ .none = {} }),
        ')' => try makeToken(state, tokens, allocator, .RIGHT_PAREN, .{ .none = {} }),
        '{' => try makeToken(state, tokens, allocator, .LEFT_BRACE, .{ .none = {} }),
        '}' => try makeToken(state, tokens, allocator, .RIGHT_BRACE, .{ .none = {} }),
        '[' => try makeToken(state, tokens, allocator, .LEFT_BRACKET, .{ .none = {} }),
        ']' => try makeToken(state, tokens, allocator, .RIGHT_BRACKET, .{ .none = {} }),
        ',' => try makeToken(state, tokens, allocator, .COMMA, .{ .none = {} }),
        '.' => try makeToken(state, tokens, allocator, .DOT, .{ .none = {} }),
        '+' => try makeToken(state, tokens, allocator, .PLUS, .{ .none = {} }),
        '*' => try makeToken(state, tokens, allocator, .STAR, .{ .none = {} }),
        '^' => try makeToken(state, tokens, allocator, .CARET, .{ .none = {} }),
        '!' => try makeToken(state, tokens, allocator, .BANG, .{ .none = {} }),
        '?' => try makeToken(state, tokens, allocator, .QUESTION, .{ .none = {} }),
        '-' => {
            if (state.match('>')) {
                try makeToken(state, tokens, allocator, .ARROW, .{ .none = {} });
            } else {
                try makeToken(state, tokens, allocator, .MINUS, .{ .none = {} });
            }
        },
        '/' => {
            if (state.match('/')) {
                commentLexeme(state);
            } else {
                try makeToken(state, tokens, allocator, .SLASH, .{ .none = {} });
            }
        },
        '=' => {
            if (state.match('=')) {
                try makeToken(state, tokens, allocator, .EQUAL_EQUAL, .{ .none = {} });
            } else {
                try makeToken(state, tokens, allocator, .EQUAL, .{ .none = {} });
            }
        },
        '<' => {
            if (state.match('=')) {
                try makeToken(state, tokens, allocator, .LESS_EQUAL, .{ .none = {} });
            } else {
                try makeToken(state, tokens, allocator, .LESS, .{ .none = {} });
            }
        },
        '>' => {
            if (state.match('=')) {
                try makeToken(state, tokens, allocator, .GREATER_EQUAL, .{ .none = {} });
            } else {
                try makeToken(state, tokens, allocator, .GREATER, .{ .none = {} });
            }
        },
        ':' => {
            if (state.match('=')) {
                try makeToken(state, tokens, allocator, .COLON_EQUAL, .{ .none = {} });
            } else {
                try makeToken(state, tokens, allocator, .COLON, .{ .none = {} });
            }
        },
        '|' => {
            if (state.match('>')) {
                try makeToken(state, tokens, allocator, .PIPE, .{ .none = {} });
            } else {
                try undefinedLexeme(state);
            }
        },
        '"' => {
            const str = try stringLiteral(state, allocator);
            try makeToken(state, tokens, allocator, .STRING, .{ .string = str });
        },
        else => {
            if (isNumber(c)) {
                const literal = try scanNumber(state);
                try makeToken(state, tokens, allocator, .NUMBER, literal);
            } else if (isAlpha(c)) {
                const result = identifier(state);
                try makeToken(state, tokens, allocator, result.token_type, result.literal);
            } else {
                try undefinedLexeme(state);
            }
        },
    }
}

fn undefinedLexeme(state: *LexState) !void {
    errors.report(state.line, "", "Unexpected character.");
    return error.UnexpectedCharacter;
}

fn commentLexeme(state: *LexState) void {
    while (!state.isAtEnd() and state.peek() != '\n') {
        _ = state.advance();
    }
}

fn identifier(state: *LexState) struct { token_type: TokenType, literal: Literal } {
    while (isAlpha(state.peek()) or isNumber(state.peek())) {
        _ = state.advance();
    }

    const word = state.source[state.start..state.current];
    const token_type = KeywordMap.get(word) orelse .IDENTIFIER;

    // Special case: keywords with literal values
    const literal = switch (token_type) {
        .BOOLEAN => if (std.mem.eql(u8, word, "true"))
            Literal{ .boolean = true }
        else
            Literal{ .boolean = false },
        .NONE => Literal{ .none = {} },
        else => Literal{ .none = {} }, // Default for identifiers
    };

    return .{ .token_type = token_type, .literal = literal };
}

fn isAlpha(token: u8) bool {
    return std.ascii.isAlphabetic(token) or token == '_';
}

fn isNumber(token: u8) bool {
    return std.ascii.isDigit(token);
}

fn scanNumber(state: *LexState) !Literal {
    while (!state.isAtEnd() and isNumber(state.peek())) {
        _ = state.advance();
    }

    if (!state.isAtEnd() and state.peek() == '.' and isNumber(state.peekNext())) {
        _ = state.advance();
        while (!state.isAtEnd() and isNumber(state.peek())) {
            _ = state.advance();
        }
    }

    const lexeme = state.source[state.start..state.current];
    const float_val = try std.fmt.parseFloat(f64, lexeme);
    return .{ .number = float_val };
}

fn stringLiteral(state: *LexState, allocator: std.mem.Allocator) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
    var prev: u8 = 0;

    while (!state.isAtEnd()) {
        const ch = state.advance();

        if (ch == '"' and prev != '\\') {
            return buffer.toOwnedSlice(allocator);
        }

        if (ch == '\\') {
            if (state.isAtEnd()) break;
            const next = state.advance();
            const escaped = switch (next) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                else => next,
            };
            try buffer.append(allocator, escaped);
            prev = next;
        } else {
            try buffer.append(allocator, ch);
            prev = ch;
        }

        if (ch == '\n') state.line += 1;
    }

    errors.report(state.line, "", "Unterminated string literal (missing closing quote).");
    buffer.deinit(allocator);
    return error.UnterminatedString;
}

fn makeToken(
    state: *LexState,
    tokens: *std.ArrayList(Token),
    allocator: std.mem.Allocator,
    t: TokenType,
    literal: Literal,
) !void {
    var lit = literal;
    switch (t) {
        .NONE => lit = .{ .none = {} },
        else => {},
    }

    const no_lexeme_tokens = [_]TokenType{ .NEWLINE, .EOF, .INDENT, .DEDENT };

    const lexeme = if (std.mem.indexOfScalar(TokenType, &no_lexeme_tokens, t) != null)
        ""
    else
        state.source[state.start..state.current];

    const token = Token{
        .type = t,
        .lexeme = lexeme,
        .literal = lit,
        .line = state.line,
        .column = state.start_column,
    };

    try tokens.append(allocator, token);
}

// Tests
const testing = std.testing;

test "tokenize simple number" {
    const allocator = testing.allocator;

    const source = "42";
    const tokens = try tokenize(source, allocator);
    defer freeTokens(tokens, allocator);

    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqual(TokenType.NUMBER, tokens[0].type);
    try testing.expectEqual(@as(f64, 42.0), tokens[0].literal.?.number);
    try testing.expectEqual(TokenType.EOF, tokens[1].type);
}

test "tokenize assignment" {
    const allocator = testing.allocator;

    const source = "x := 10";
    const tokens = try tokenize(source, allocator);
    defer freeTokens(tokens, allocator);

    try testing.expectEqual(@as(usize, 4), tokens.len);
    try testing.expectEqual(TokenType.IDENTIFIER, tokens[0].type);
    try testing.expectEqualStrings("x", tokens[0].lexeme);
    try testing.expectEqual(TokenType.COLON_EQUAL, tokens[1].type);
    try testing.expectEqual(TokenType.NUMBER, tokens[2].type);
    try testing.expectEqual(@as(f64, 10.0), tokens[2].literal.?.number);
    try testing.expectEqual(TokenType.EOF, tokens[3].type);
}

test "tokenize multiplication" {
    const allocator = testing.allocator;

    const source = "3 * 4";
    const tokens = try tokenize(source, allocator);
    defer freeTokens(tokens, allocator);

    try testing.expectEqual(@as(usize, 4), tokens.len);
    try testing.expectEqual(TokenType.NUMBER, tokens[0].type);
    try testing.expectEqual(@as(f64, 3.0), tokens[0].literal.?.number);
    try testing.expectEqual(TokenType.STAR, tokens[1].type);
    try testing.expectEqual(TokenType.NUMBER, tokens[2].type);
    try testing.expectEqual(@as(f64, 4.0), tokens[2].literal.?.number);
    try testing.expectEqual(TokenType.EOF, tokens[3].type);
}

test "tokenize string literal" {
    const allocator = testing.allocator;

    const source = "\"hello world\"";
    const tokens = try tokenize(source, allocator);
    defer freeTokens(tokens, allocator);

    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqual(TokenType.STRING, tokens[0].type);
    try testing.expectEqualStrings("hello world", tokens[0].literal.?.string);
    try testing.expectEqual(TokenType.EOF, tokens[1].type);
}

test "tokenize multiline with indentation - continuation" {
    const allocator = testing.allocator;

    const source =
        \\x := 5 +
        \\  5
    ;
    const tokens = try tokenize(source, allocator);
    defer freeTokens(tokens, allocator);

    try testing.expect(tokens.len > 0);
}

test "tokenize multiline with indentation - assignment value" {
    const allocator = testing.allocator;

    const source =
        \\x :=
        \\  5 + 10
    ;
    const tokens = try tokenize(source, allocator);
    defer freeTokens(tokens, allocator);

    try testing.expect(tokens.len > 0);
}

test "tokenize indent/dedent matching - if block" {
    const allocator = testing.allocator;

    const source =
        \\if true ->
        \\  x := 5
        \\  y := 10
        \\z := 15
    ;

    const tokens = try tokenize(source, allocator);
    defer freeTokens(tokens, allocator);

    try testing.expect(tokens.len > 0);
}

test "tokenize multiple statements" {
    const allocator = testing.allocator;

    const source =
        \\x := 5
        \\y := 10
        \\z := 15
    ;

    const tokens = try tokenize(source, allocator);
    defer freeTokens(tokens, allocator);

    try testing.expect(tokens.len > 0);
}

test "tokenize invalid orphan indentation" {
    const allocator = testing.allocator;

    const source =
        \\x := 5
        \\  y := 10
    ;

    const result = tokenize(source, allocator);
    try testing.expectError(error.UnexpectedIndentation, result);
}
