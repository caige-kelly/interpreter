const std = @import("std");
const errors = @import("error.zig");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Literal = @import("ast.zig").Literal;
const KeywordMap = @import("token.zig").KeywordMap;

// Pure data - parsing state
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

// Main entry point - free function
pub fn tokenize(source: []const u8, allocator: std.mem.Allocator) ![]Token {
    var state = LexState{ .source = source };
    var tokens = try std.ArrayList(Token).initCapacity(allocator, 0);
    var indent_stack = try std.ArrayList(usize).initCapacity(allocator, 0);
    defer indent_stack.deinit(allocator);

    try indent_stack.append(allocator, 0);

    while (!state.isAtEnd()) {
        if (state.at_line_start and !state.isAtEnd()) {
            try handleIndentation(&state, &tokens, &indent_stack, allocator);
            state.at_line_start = false;
        }

        if (state.isAtEnd()) break;

        state.start = state.current;
        state.start_column = state.column;

        try scanToken(&state, &tokens, allocator);
    }

    // Add EOF token
    // Before adding EOF token
    while (indent_stack.items.len > 1) {
        _ = indent_stack.pop();
        try tokens.append(allocator, .{
            .type = .DEDENT,
            .lexeme = "",
            .line = state.line,
            .column = state.column,
            .literal = null,
        });
    }

    state.start = state.current;
    state.start_column = state.column;
    try makeToken(&state, &tokens, allocator, .EOF, .none);

    const raw_tokens = try tokens.toOwnedSlice(allocator);
    return convertToBlocks(raw_tokens, allocator);
}

fn convertToBlocks(tokens: []Token, allocator: std.mem.Allocator) ![]Token {
    var result = try std.ArrayList(Token).initCapacity(allocator, 0);
    var block_depth: usize = 0;

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
                    // Check what comes AFTER the indent
                    const after_indent = if (i + 2 < tokens.len) tokens[i + 2].type else TokenType.EOF;

                    // Assignment continuation: := followed by newline+indent
                    // Allow any expression to start on the next line
                    if (prev_type == .COLON_EQUAL or prev_type == .COLON or prev_type == .EQUAL) {
                        // Skip the newline and indent, the value expression follows
                        i += 2;
                        continue;
                    }
                    // BLOCK_START: -> followed by indent (for arrow functions/blocks)
                    else if (prev_type == .ARROW) {
                        try result.append(allocator, .{
                            .type = .BLOCK_START,
                            .lexeme = "",
                            .line = token.line,
                            .column = token.column,
                            .literal = null,
                        });
                        block_depth += 1;
                        i += 2;
                        continue;
                    }
                    // Valid continuation: operator BEFORE newline OR operator AFTER indent
                    else if ((prev_type == .PIPE or prev_type == .PLUS or
                        prev_type == .MINUS or prev_type == .STAR or
                        prev_type == .SLASH or prev_type == .DOT) or
                        (after_indent == .PIPE or after_indent == .PLUS or
                            after_indent == .MINUS or after_indent == .STAR or
                            after_indent == .SLASH or after_indent == .DOT))
                    {
                        i += 2; // Skip NEWLINE and INDENT - continuation is OK
                        continue;
                    }
                    // ERROR: Indent with no valid continuation
                    else {
                        return error.UnexpectedIndentation;
                    }
                } else {
                    // NO INDENT - check what's AFTER the newline
                    const next_type = if (i + 1 < tokens.len) tokens[i + 1].type else TokenType.EOF;

                    // Skip newline if next token is a continuation operator
                    if (next_type == .PIPE or next_type == .PLUS or
                        next_type == .MINUS or next_type == .STAR or
                        next_type == .SLASH or next_type == .DOT)
                    {
                        i += 1;
                        continue;
                    }

                    // Keep newline for statement separation
                    try result.append(allocator, token);
                    i += 1;
                }
            },
            .DEDENT => {
                // Only emit BLOCK_END if we're in a block
                if (block_depth > 0) {
                    try result.append(allocator, .{
                        .type = .BLOCK_END,
                        .lexeme = "",
                        .line = token.line,
                        .column = token.column,
                        .literal = null,
                    });
                    block_depth -= 1;
                }
                i += 1;
            },
            .INDENT => {
                // Standalone INDENT tokens should have been handled above
                // This shouldn't happen but skip it if it does
                i += 1;
            },
            else => {
                try result.append(allocator, token);
                i += 1;
            },
        }
    }

    // Close any remaining blocks
    while (block_depth > 0) {
        try result.append(allocator, .{
            .type = .BLOCK_END,
            .lexeme = "",
            .line = if (result.items.len > 0) result.items[result.items.len - 1].line else 1,
            .column = if (result.items.len > 0) result.items[result.items.len - 1].column else 1,
            .literal = null,
        });
        block_depth -= 1;
    }

    return result.toOwnedSlice(allocator);
}

fn handleIndentation(
    state: *LexState,
    tokens: *std.ArrayList(Token),
    indent_stack: *std.ArrayList(usize),
    allocator: std.mem.Allocator,
) !void {
    var indent: usize = 0;

    while (!state.isAtEnd() and (state.peek() == ' ' or state.peek() == '\t')) {
        if (state.peek() == ' ') {
            indent += 1;
        } else {
            indent += 4;
        }
        _ = state.advance();
    }

    if (state.isAtEnd() or state.peek() == '\n' or state.peek() == '/') {
        while (!state.isAtEnd() and state.peek() != '\n') {
            _ = state.advance();
        }
        return;
    }

    const current_indent = indent_stack.items[indent_stack.items.len - 1];

    if (indent > current_indent) {
        try indent_stack.append(allocator, indent);
        try tokens.append(allocator, .{
            .type = .INDENT,
            .lexeme = "",
            .line = state.line,
            .column = state.column,
            .literal = null,
        });
    } else if (indent < current_indent) {
        while (indent_stack.items.len > 1 and indent_stack.items[indent_stack.items.len - 1] > indent) {
            _ = indent_stack.pop();
            try tokens.append(allocator, .{
                .type = .DEDENT,
                .lexeme = "",
                .line = state.line,
                .column = state.column,
                .literal = null,
            });
        }
    }
}

fn scanToken(
    state: *LexState,
    tokens: *std.ArrayList(Token),
    allocator: std.mem.Allocator,
) !void {
    const c = state.advance();

    switch (c) {
        '(' => return makeToken(state, tokens, allocator, .LEFT_PAREN, .none),
        ')' => return makeToken(state, tokens, allocator, .RIGHT_PAREN, .none),
        '{' => return makeToken(state, tokens, allocator, .LEFT_BRACE, .none),
        '}' => return makeToken(state, tokens, allocator, .RIGHT_BRACE, .none),
        '[' => return makeToken(state, tokens, allocator, .LEFT_BRACKET, .none),
        ']' => return makeToken(state, tokens, allocator, .RIGHT_BRACKET, .none),
        ',' => return makeToken(state, tokens, allocator, .COMMA, .none),
        '.' => return makeToken(state, tokens, allocator, .DOT, .none),
        ':' => return if (state.match('='))
            makeToken(state, tokens, allocator, .COLON_EQUAL, .none)
        else
            makeToken(state, tokens, allocator, .COLON, .none),
        '+' => return makeToken(state, tokens, allocator, .PLUS, .none),
        '-' => {
            if (state.match('>')) return makeToken(state, tokens, allocator, .ARROW, .none);
            return makeToken(state, tokens, allocator, .MINUS, .none);
        },
        '*' => return makeToken(state, tokens, allocator, .STAR, .none),
        '@' => return makeToken(state, tokens, allocator, .AT, .none),
        '#' => return makeToken(state, tokens, allocator, .HASH, .none),
        '^' => return makeToken(state, tokens, allocator, .CARET, .none),
        '?' => return makeToken(state, tokens, allocator, .QUESTION, .none),

        '|' => return if (state.match('>'))
            makeToken(state, tokens, allocator, .PIPE, .none)
        else
            undefinedLexeme(state),
        '"' => {
            const str = try stringLiteral(state, allocator);
            return makeToken(state, tokens, allocator, .STRING, .{ .string = str });
        },
        '_' => return makeToken(state, tokens, allocator, .UNDERSCORE, .none),
        '/' => return if (state.match('/'))
            commentLexeme(state)
        else
            makeToken(state, tokens, allocator, .SLASH, .none),
        '!' => return if (state.match('='))
            makeToken(state, tokens, allocator, .BANG_EQUAL, .none)
        else
            makeToken(state, tokens, allocator, .BANG, .none),
        '=' => return if (state.match('='))
            makeToken(state, tokens, allocator, .EQUAL_EQUAL, .none)
        else
            makeToken(state, tokens, allocator, .EQUAL, .none),
        '<' => return if (state.match('='))
            makeToken(state, tokens, allocator, .LESS_EQUAL, .none)
        else
            makeToken(state, tokens, allocator, .LESS, .none),
        '>' => return if (state.match('='))
            makeToken(state, tokens, allocator, .GREATER_EQUAL, .none)
        else
            makeToken(state, tokens, allocator, .GREATER, .none),
        ' ', '\r', '\t' => return,
        '\n' => return newLine(state, tokens, allocator),
        else => if (isNumber(c)) {
            const literal = try scanNumber(state);
            return makeToken(state, tokens, allocator, .NUMBER, literal);
        } else if (isAlpha(c)) {
            // Scan the identifier/keyword
            while (isAlpha(state.peek()) or isNumber(state.peek())) {
                _ = state.advance();
            }

            const word = state.source[state.start..state.current];
            const token_type = KeywordMap.get(word) orelse .IDENTIFIER;

            // Create literal value for booleans
            const literal: Literal = if (token_type == .BOOLEAN) blk: {
                if (std.mem.eql(u8, word, "true")) {
                    break :blk .{ .boolean = true };
                } else {
                    break :blk .{ .boolean = false };
                }
            } else .none;

            return makeToken(state, tokens, allocator, token_type, literal);
        } else {
            return undefinedLexeme(state);
        },
    }
}

fn newLine(state: *LexState, tokens: *std.ArrayList(Token), allocator: std.mem.Allocator) !void {
    state.column = 0;
    state.line += 1;
    state.at_line_start = true;
    try makeToken(state, tokens, allocator, .NEWLINE, .none);
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

fn identifier(state: *LexState) TokenType {
    while (isAlpha(state.peek()) or isNumber(state.peek())) {
        _ = state.advance();
    }

    const word = state.source[state.start..state.current];
    return KeywordMap.get(word) orelse .IDENTIFIER;
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "42";
    const tokens = try tokenize(source, arena.allocator());

    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqual(TokenType.NUMBER, tokens[0].type);
    try testing.expectEqual(@as(f64, 42.0), tokens[0].literal.?.number);
    try testing.expectEqual(TokenType.EOF, tokens[1].type);
}

test "tokenize assignment" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "x := 10";
    const tokens = try tokenize(source, arena.allocator());

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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "3 * 4";
    const tokens = try tokenize(source, arena.allocator());

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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = "\"hello world\"";
    const tokens = try tokenize(source, arena.allocator());

    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqual(TokenType.STRING, tokens[0].type);
    try testing.expectEqualStrings("hello world", tokens[0].literal.?.string);
    try testing.expectEqual(TokenType.EOF, tokens[1].type);
}

test "tokenize multiline with indentation - continuation" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\x := 5 +
        \\  5    // VALID: operator continuation
    ;
    const tokens = try tokenize(source, arena.allocator());
    // This should tokenize successfully
    try testing.expect(tokens.len > 0);
}

test "tokenize multiline with indentation - assignment value" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\x :=
        \\  5 + 10    // VALID: assignment value on next line
    ;
    const tokens = try tokenize(source, arena.allocator());
    try testing.expect(tokens.len > 0);
}

test "tokenize indent/dedent matching - if block" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\if true ->
        \\  x := 5
        \\  y := 10   // VALID: inside a block
        \\z := 15
    ;

    const tokens = try tokenize(source, arena.allocator());
    // Should have BLOCK_START after ->, statements inside, BLOCK_END before z
    try testing.expect(tokens.len > 0);
}

test "tokenize multiple statements" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\x := 5
        \\y := 10    // VALID: same indentation level
        \\z := 15
    ;

    const tokens = try tokenize(source, arena.allocator());
    try testing.expect(tokens.len > 0);
}

test "tokenize invalid orphan indentation" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\x := 5
        \\  y := 10   // INVALID: orphan indented statement
    ;

    const result = tokenize(source, arena.allocator());
    try testing.expectError(error.UnexpectedIndentation, result);
}
