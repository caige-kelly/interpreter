const std = @import("std");
const testing = std.testing;
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Ast = @import("ast.zig");
const Type = @import("ast.zig").Type;
const Lexer = @import("lexer.zig");

pub const ParseError = error{
    UnexpectedToken,
    InvalidAssignmentTarget,
    ExpectedToken,
    OutOfMemory,
};

// Pure data
const ParseState = struct {
    tokens: []const Token,
    current: usize,

    fn peek(self: *const ParseState) Token {
        return self.tokens[self.current];
    }

    fn isAtEnd(self: *const ParseState) bool {
        return self.peek().type == .EOF;
    }

    fn consume(self: *ParseState) Token {
        if (!self.isAtEnd()) self.current += 1;
        return self.tokens[self.current - 1];
    }

    fn match(self: *ParseState, t: TokenType) bool {
        if (!self.isAtEnd() and self.peek().type == t) {
            _ = self.consume();
            return true;
        }
        return false;
    }
};

// Main entry point - free function
pub fn parse(tokens: []const Token, allocator: std.mem.Allocator) !Ast.Program {
    var state = ParseState{ .tokens = tokens, .current = 0 };
    var exprs = try std.ArrayList(Ast.Expr).initCapacity(allocator, 0);

    while (!state.isAtEnd()) {
        skipNewlines(&state);
        if (state.isAtEnd()) break;

        const expr = try parseAssignment(&state, allocator);
        std.debug.print("expr {any}\n", .{expr});
        try exprs.append(allocator, expr);
    }

    return Ast.Program{
        .expressions = try exprs.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn parseAssignment(state: *ParseState, allocator: std.mem.Allocator) !Ast.Expr {
    const expr = try parsePipeline(state, allocator);

    var explicit_type: ?Type = null;

    if (state.match(.COLON_EQUAL)) {
        // inferred type
    } else if (state.match(.COLON)) {
        // explicit type
        const type_name = state.consume();
        explicit_type = try parseTypeName(type_name.lexeme);

        if (!state.match(.EQUAL)) {
            return error.UnexpectedToken;
        }
    } else {
        // Not an assignment, just return the expression
        return expr;
    }

    // Now parse the value
    const value = if (state.match(.BLOCK_START)) blk: {
        const val = try parsePipeline(state, allocator);
        if (!state.match(.BLOCK_END)) {
            return error.ExpectedBlockEnd;
        }
        break :blk val;
    } else blk: {
        break :blk try parsePipeline(state, allocator);
    };

    // Create the assignment
    switch (expr) {
        .identifier => |name| {
            const value_ptr = try allocator.create(Ast.Expr);
            value_ptr.* = value;
            return Ast.Expr{
                .assignment = .{
                    .name = name,
                    .type = explicit_type,
                    .value = value_ptr,
                },
            };
        },
        else => return error.InvalidAssignmentTarget,
    }
}

fn parsePipeline(state: *ParseState, allocator: std.mem.Allocator) !Ast.Expr {
    std.debug.print("parsePipeline start, current token: {any}\n", .{state.peek().type});

    var left = try parsEquality(state, allocator);

    while (state.match(.PIPE)) {
        std.debug.print("Found |>, current token after: {any}\n", .{state.peek().type});

        skipNewlines(state);
        const right = try parsEquality(state, allocator);

        const left_ptr = try allocator.create(Ast.Expr);
        left_ptr.* = left;

        const right_ptr = try allocator.create(Ast.Expr);
        right_ptr.* = right;

        left = Ast.Expr{
            .pipe = .{
                .left = left_ptr,
                .right = right_ptr,
            },
        };
    }
    std.debug.print("parsePipeline end, current token: {any}\n", .{state.peek().type});

    return left;
}

fn parsEquality(state: *ParseState, allocator: std.mem.Allocator) !Ast.Expr {
    var left = try parseComparison(state, allocator);

    while (state.peek().type == .EQUAL_EQUAL or state.peek().type == .BANG_EQUAL) {
        const operator = state.consume();
        skipNewlines(state);

        const right = try parseComparison(state, allocator);

        const left_ptr = try allocator.create(Ast.Expr);
        left_ptr.* = left;

        const right_ptr = try allocator.create(Ast.Expr);
        right_ptr.* = right;

        left = Ast.Expr{
            .binary = .{
                .left = left_ptr,
                .operator = operator.type,
                .right = right_ptr,
            },
        };
    }

    return left;
}

fn parseComparison(state: *ParseState, allocator: std.mem.Allocator) !Ast.Expr {
    var left = try parseBinary(state, allocator);

    while (state.peek().type == .LESS or
        state.peek().type == .LESS_EQUAL or
        state.peek().type == .GREATER or
        state.peek().type == .GREATER_EQUAL)
    {
        const operator = state.consume();
        skipNewlines(state);

        const right = try parseBinary(state, allocator);

        const left_ptr = try allocator.create(Ast.Expr);
        left_ptr.* = left;

        const right_ptr = try allocator.create(Ast.Expr);
        right_ptr.* = right;

        left = Ast.Expr{
            .binary = .{
                .left = left_ptr,
                .operator = operator.type,
                .right = right_ptr,
            },
        };
    }

    return left;
}

fn parseBinary(state: *ParseState, allocator: std.mem.Allocator) !Ast.Expr {
    var left = try parseMultiplicative(state, allocator);

    while (state.peek().type == .PLUS or state.peek().type == .MINUS) {
        const operator = state.consume();
        skipNewlines(state);

        const right = try parseMultiplicative(state, allocator);

        const left_ptr = try allocator.create(Ast.Expr);
        left_ptr.* = left;

        const right_ptr = try allocator.create(Ast.Expr);
        right_ptr.* = right;

        left = Ast.Expr{
            .binary = .{
                .left = left_ptr,
                .operator = operator.type,
                .right = right_ptr,
            },
        };
    }

    return left;
}

fn parseMultiplicative(state: *ParseState, allocator: std.mem.Allocator) !Ast.Expr {
    var left = try parsePolicy(state, allocator);

    while (state.peek().type == .STAR or state.peek().type == .SLASH) {
        const operator = state.consume();
        skipNewlines(state);

        const right = try parsePolicy(state, allocator);

        const left_ptr = try allocator.create(Ast.Expr);
        left_ptr.* = left;

        const right_ptr = try allocator.create(Ast.Expr);
        right_ptr.* = right;

        left = Ast.Expr{
            .binary = .{
                .left = left_ptr,
                .operator = operator.type,
                .right = right_ptr,
            },
        };
    }

    return left;
}

fn parsePolicy(state: *ParseState, allocator: std.mem.Allocator) !Ast.Expr {
    // handle prefix policies
    if (state.peek().type == .CARET or
        state.peek().type == .QUESTION or
        state.peek().type == .BANG)
    {
        const token = state.consume();
        skipNewlines(state);

        const operand = try parseUnary(state, allocator);
        const operand_ptr = try allocator.create(Ast.Expr);
        operand_ptr.* = operand;

        const policy_val = switch (token.type) {
            .CARET => Ast.PolicyValue.keep_wrapped,
            .QUESTION => Ast.PolicyValue.unwrap_or_none,
            .BANG => Ast.PolicyValue.panic_on_error,
            else => Ast.PolicyValue.none,
        };

        return Ast.Expr{
            .policy = .{
                .policy = policy_val,
                .expr = operand_ptr,
            },
        };
    }

    // otherwise just parse normally
    return parseUnary(state, allocator);
}

fn parseUnary(state: *ParseState, allocator: std.mem.Allocator) !Ast.Expr {
    // Only true unaries should stay here. Keep MINUS; if you want logical-not,
    // consider a `not` keyword to avoid ambiguity with bang policy.
    if (state.peek().type == .MINUS) {
        const op = state.consume();
        skipNewlines(state);
        const operand = try parseUnary(state, allocator);

        const operand_ptr = try allocator.create(Ast.Expr);
        operand_ptr.* = operand;

        return Ast.Expr{
            .unary = .{
                .operator = op.type,
                .operand = operand_ptr,
            },
        };
    }

    return parsePrimary(state, allocator);
}

fn parsePrimary(state: *ParseState, allocator: std.mem.Allocator) !Ast.Expr {
    _ = allocator;
    const token = state.consume();

    return switch (token.type) {
        .NUMBER => Ast.Expr{ .literal = token.literal.? },
        .STRING => Ast.Expr{ .literal = token.literal.? },
        .BOOLEAN => Ast.Expr{ .literal = token.literal.? },
        .NONE => Ast.Expr{ .literal = token.literal.? },
        .IDENTIFIER => Ast.Expr{ .identifier = token.lexeme },
        else => |t| {
            std.debug.print("token {any}\n", .{t});
            return error.UnexpectedToken;
        },
    };
}

fn parseTypeName(name: []const u8) !Type {
    if (std.mem.eql(u8, name, "number")) return .number;
    if (std.mem.eql(u8, name, "string")) return .string;
    if (std.mem.eql(u8, name, "boolean")) return .boolean;
    if (std.mem.eql(u8, name, "none")) return .none;
    return error.UnknownType;
}

fn skipNewlines(state: *ParseState) void {
    while (state.peek().type == .NEWLINE) {
        _ = state.consume();
    }
}

// Tests
const lex = @import("lexer.zig");

test "parse multiplication - manual tokens" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tokens = [_]Token{
        Token{ .type = .IDENTIFIER, .lexeme = "x", .literal = null, .line = 1, .column = 1 },
        Token{ .type = .COLON_EQUAL, .lexeme = ":=", .literal = null, .line = 1, .column = 3 },
        Token{ .type = .NUMBER, .lexeme = "3", .literal = .{ .number = 3.0 }, .line = 1, .column = 6 },
        Token{ .type = .STAR, .lexeme = "*", .literal = null, .line = 1, .column = 8 },
        Token{ .type = .NUMBER, .lexeme = "4", .literal = .{ .number = 4.0 }, .line = 1, .column = 10 },
        Token{ .type = .EOF, .lexeme = "", .literal = null, .line = 1, .column = 11 },
    };

    var program = try parse(&tokens, a);
    defer program.deinit();

    try testing.expectEqual(@as(usize, 1), program.expressions.len);
    const stmt = program.expressions[0];
    try testing.expect(stmt == .assignment);

    const assign = stmt.assignment;
    try testing.expectEqualStrings("x", assign.name);
    try testing.expect(assign.value.* == .binary);

    const binary = assign.value.binary;
    try testing.expectEqual(TokenType.STAR, binary.operator);

    try testing.expect(binary.left.* == .literal);
    try testing.expectEqual(@as(f64, 3.0), binary.left.literal.number);

    try testing.expect(binary.right.* == .literal);
    try testing.expectEqual(@as(f64, 4.0), binary.right.literal.number);
}

test "parse simple pipeline: 5 |> 10" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tokens = [_]Token{
        Token{ .type = .NUMBER, .lexeme = "5", .literal = .{ .number = 5.0 }, .line = 1, .column = 1 },
        Token{ .type = .PIPE, .lexeme = "|>", .literal = null, .line = 1, .column = 3 },
        Token{ .type = .NUMBER, .lexeme = "10", .literal = .{ .number = 10.0 }, .line = 1, .column = 6 },
        Token{ .type = .EOF, .lexeme = "", .literal = null, .line = 1, .column = 8 },
    };

    var program = try parse(&tokens, a);
    defer program.deinit();

    try testing.expectEqual(@as(usize, 1), program.expressions.len);
    const expr = program.expressions[0];
    try testing.expect(expr == .pipe);

    const pipe = expr.pipe;
    try testing.expect(pipe.left.* == .literal);
    try testing.expectEqual(@as(f64, 5.0), pipe.left.literal.number);
    try testing.expect(pipe.right.* == .literal);
    try testing.expectEqual(@as(f64, 10.0), pipe.right.literal.number);
}

test "parse policy unary: x := ?5" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tokens = [_]Token{
        Token{ .type = .IDENTIFIER, .lexeme = "x", .literal = null, .line = 1, .column = 1 },
        Token{ .type = .COLON_EQUAL, .lexeme = ":=", .literal = null, .line = 1, .column = 3 },
        Token{ .type = .QUESTION, .lexeme = "?", .literal = null, .line = 1, .column = 6 },
        Token{ .type = .NUMBER, .lexeme = "5", .literal = .{ .number = 5.0 }, .line = 1, .column = 7 },
        Token{ .type = .EOF, .lexeme = "", .literal = null, .line = 1, .column = 8 },
    };

    var program = try parse(&tokens, a);
    defer program.deinit();

    try testing.expectEqual(@as(usize, 1), program.expressions.len);
    const stmt = program.expressions[0];
    try testing.expect(stmt == .assignment);

    const assign = stmt.assignment;
    try testing.expectEqualStrings("x", assign.name);

    try testing.expect(assign.value.* == .policy);
    try testing.expectEqual(Ast.PolicyValue.unwrap_or_none, assign.value.policy.policy);
    try testing.expect(assign.value.policy.expr.* == .literal);
    try testing.expectEqual(@as(f64, 5.0), assign.value.policy.expr.literal.number);
}

test "parse pipeline with policies: ?5 |> !10 |> ^7" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tokens = [_]Token{
        Token{ .type = .QUESTION, .lexeme = "?", .literal = null, .line = 1, .column = 1 },
        Token{ .type = .NUMBER, .lexeme = "5", .literal = .{ .number = 5.0 }, .line = 1, .column = 2 },
        Token{ .type = .PIPE, .lexeme = "|>", .literal = null, .line = 1, .column = 4 },
        Token{ .type = .BANG, .lexeme = "!", .literal = null, .line = 1, .column = 7 },
        Token{ .type = .NUMBER, .lexeme = "10", .literal = .{ .number = 10.0 }, .line = 1, .column = 8 },
        Token{ .type = .PIPE, .lexeme = "|>", .literal = null, .line = 1, .column = 11 },
        Token{ .type = .CARET, .lexeme = "^", .literal = null, .line = 1, .column = 14 },
        Token{ .type = .NUMBER, .lexeme = "7", .literal = .{ .number = 7.0 }, .line = 1, .column = 15 },
        Token{ .type = .EOF, .lexeme = "", .literal = null, .line = 1, .column = 16 },
    };

    var program = try parse(&tokens, a);
    defer program.deinit();

    try testing.expectEqual(@as(usize, 1), program.expressions.len);
    const expr = program.expressions[0];

    try testing.expect(expr == .pipe);
    const outer_pipe = expr.pipe;

    // Outer right: ^7
    try testing.expect(outer_pipe.right.* == .policy);
    try testing.expectEqual(Ast.PolicyValue.keep_wrapped, outer_pipe.right.policy.policy);
    try testing.expect(outer_pipe.right.policy.expr.* == .literal);
    try testing.expectEqual(@as(f64, 7.0), outer_pipe.right.policy.expr.literal.number);

    // Left side: ?5 |> !10
    try testing.expect(outer_pipe.left.* == .pipe);
    const inner_pipe = outer_pipe.left.pipe;

    try testing.expect(inner_pipe.left.* == .policy);
    try testing.expectEqual(Ast.PolicyValue.unwrap_or_none, inner_pipe.left.policy.policy);
    try testing.expect(inner_pipe.left.policy.expr.* == .literal);
    try testing.expectEqual(@as(f64, 5.0), inner_pipe.left.policy.expr.literal.number);

    try testing.expect(inner_pipe.right.* == .policy);
    try testing.expectEqual(Ast.PolicyValue.panic_on_error, inner_pipe.right.policy.policy);
    try testing.expect(inner_pipe.right.policy.expr.* == .literal);
    try testing.expectEqual(@as(f64, 10.0), inner_pipe.right.policy.expr.literal.number);
}

test "parse pipeline with indentation" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\x := 
        \\  5 +
        \\  5
    ;

    const tokens = try Lexer.tokenize(source, arena.allocator());
    const program = try parse(tokens, arena.allocator());

    // Should have 1 expression (the assignment)
    try testing.expectEqual(@as(usize, 1), program.expressions.len);

    // The assignment value should be a pipeline
    const assignment = program.expressions[0].assignment;
    try testing.expect(assignment.value.* == .binary); // Pipeline is binary expr
    //std.debug.print("value {any}\n",.{assignment.value.*});
}

test "assignment with pipeline continuation" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\x := "hello"
        \\  |> uppercase
    ;

    const tokens = try Lexer.tokenize(source, arena.allocator());
    
    // DEBUG: Print the tokens
    std.debug.print("\nTokens generated:\n", .{});
    for (tokens) |token| {
        std.debug.print("  {any}\n", .{token.type});
    }
    
    const program = try parse(tokens, arena.allocator());
    try testing.expectEqual(@as(usize, 1), program.expressions.len);
}


test "assignment value on indented line" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\x :=
        \\  5 + 10
    ;
    
    const tokens = try Lexer.tokenize(source, arena.allocator());
    
    std.debug.print("\nTokens:\n", .{});
    for (tokens) |t| std.debug.print("  {any}\n", .{t.type});
    
    const program = try parse(tokens, arena.allocator());
    try testing.expectEqual(@as(usize, 1), program.expressions.len);
}

test "indented orphan expression errors" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\x := 5
        \\  6
    ;
    
    const tokens = try Lexer.tokenize(source, arena.allocator());
    
    std.debug.print("\nTokens:\n", .{});
    for (tokens) |t| std.debug.print("  {any}\n", .{t.type});
    
    // This should error!
    const result = parse(tokens, arena.allocator());
    try testing.expectError(error.UnexpectedIndentation, result);
}