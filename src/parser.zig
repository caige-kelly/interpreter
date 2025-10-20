const std = @import("std");
const testing = std.testing;
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Ast = @import("ast.zig");
const Type = @import("ast.zig").Type;

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
        try exprs.append(allocator, expr);
    }

    return Ast.Program{
        .expressions = try exprs.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn parseAssignment(state: *ParseState, allocator: std.mem.Allocator) !Ast.Expr {
    const expr = try parseMultiplicative(state, allocator);

    var explicit_type: ?Type = null;

    if (state.match(.COLON_EQUAL)) {
        // inferred
    } else if (state.match(.COLON)) {
        if (state.peek().type != .IDENTIFIER) {
            return error.UnexpectedToken;
        }

        const type_name = state.consume();
        explicit_type = try parseTypeName(type_name.lexeme);

        if (!state.match(.EQUAL)) {
            return error.UnexpectedToken;
        }
    } else {
        return expr;
    }

    skipNewlines(state);
    const value = try parseMultiplicative(state, allocator);

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

fn parseMultiplicative(state: *ParseState, allocator: std.mem.Allocator) !Ast.Expr {
    var left = try parsePrimary(state, allocator);

    while (state.peek().type == .STAR or state.peek().type == .SLASH) {
        const operator = state.consume();
        skipNewlines(state);

        const right = try parsePrimary(state, allocator);

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

fn parsePrimary(state: *ParseState, allocator: std.mem.Allocator) !Ast.Expr {
    _ = allocator;
    const token = state.consume();

    return switch (token.type) {
        .NUMBER => Ast.Expr{ .literal = token.literal.? },
        .STRING => Ast.Expr{ .literal = token.literal.? },
        .BOOLEAN => Ast.Expr{ .literal = token.literal.? },
        .NONE => Ast.Expr{ .literal = token.literal.? },
        .IDENTIFIER => Ast.Expr{ .identifier = token.lexeme },
        else => error.UnexpectedToken,
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

    const tokens = [_]Token{
        Token{ .type = .IDENTIFIER, .lexeme = "x", .literal = null, .line = 1, .column = 1 },
        Token{ .type = .COLON_EQUAL, .lexeme = ":=", .literal = null, .line = 1, .column = 3 },
        Token{ .type = .NUMBER, .lexeme = "3", .literal = .{ .number = 3.0 }, .line = 1, .column = 6 },
        Token{ .type = .STAR, .lexeme = "*", .literal = null, .line = 1, .column = 8 },
        Token{ .type = .NUMBER, .lexeme = "4", .literal = .{ .number = 4.0 }, .line = 1, .column = 10 },
        Token{ .type = .EOF, .lexeme = "", .literal = null, .line = 1, .column = 11 },
    };

    var program = try parse(&tokens, arena.allocator());
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
