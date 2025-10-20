const std = @import("std");
const testing = std.testing;
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Ast = @import("ast.zig");
const errors = @import("error.zig");
const Type = @import("ast.zig").Type;
const lex = @import("lexer.zig");

pub const ParseError = error{ UnexpectedToken, InvalidAssignmentTarget, ExpectedToken, NoMatchFound, OutOfMemory };

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    exprs: std.ArrayList(Ast.Expr),
    current: usize = 0,

    // -------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------
    pub fn init(tokens: []const Token, allocator: std.mem.Allocator) !Parser {
        const expressions = try std.ArrayList(Ast.Expr).initCapacity(allocator, 16);
        return .{
            .tokens = tokens,
            .allocator = allocator,
            .exprs = expressions,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.exprs.deinit(self.allocator);
    }

    // -------------------------------------------------------------
    // Entry point
    // -------------------------------------------------------------
    pub fn parse(self: *Parser) !Ast.Program {
        while (!self.isAtEnd()) {
            // Skip newlines and whitespace
            self.skipNewlines();
            if (self.isAtEnd()) break;

            const expr = try self.parseAssignment();
            try self.exprs.append(self.allocator, expr);
        }

        return Ast.Program{ .expressions = try self.exprs.toOwnedSlice(self.allocator), .allocator = self.allocator };
    }

    // -------------------------------------------------------------
    // Expression parsing (top-down precedence)
    // -------------------------------------------------------------

    fn parseAssignment(self: *Parser) !Ast.Expr {
        const expr = try self.parseMultiplicative();

        var explicit_type: ?Type = null;

        if (self.match(.COLON_EQUAL)) {
            // inferred
        } else if (self.match(.COLON)) {
            // explicit type
            if (self.peek().type != .IDENTIFIER) {
                errors.report(self.peek().line, "parse", "Expected type name after ':'");
                return error.UnexpectedToken;
            }

            const type_name = self.consume();
            explicit_type = try self.parseTypeName(type_name.lexeme);

            if (!self.match(.EQUAL)) {
                errors.report(self.peek().line, "parse", "Expected '=' after type annotation");
                return error.UnexpectedToken;
            }
        } else {
            return expr; // Not an assignment
        }

        // Common parsing for both branches
        self.skipNewlines();

        const value = try self.parseMultiplicative();

        // Extract identifier
        switch (expr) {
            .identifier => |name| {
                const value_ptr = try self.allocator.create(Ast.Expr);
                value_ptr.* = value;
                return Ast.Expr{
                    .assignment = .{
                        .name = name,
                        .type = explicit_type,
                        .value = value_ptr,
                    },
                };
            },
            else => {
                errors.report(self.peek().line, "parse", "Invalid assignment target (expected identifier)");
                return error.InvalidAssignmentTarget;
            },
        }
    }

    fn parseMultiplicative(self: *Parser) !Ast.Expr {
        var left = try self.parsePrimary(); // Start with first operand

        // Keep consuming * and / operators (left-associative)
        while (self.peek().type == .STAR or self.peek().type == .SLASH) {
            const operator = self.consume();
            self.skipNewlines();

            const right = try self.parsePrimary();

            // Allocate BOTH children on heap
            const left_ptr = try self.allocator.create(Ast.Expr);
            left_ptr.* = left; // Copy current left into heap

            const right_ptr = try self.allocator.create(Ast.Expr);
            right_ptr.* = right; // Copy right into heap

            // Build new binary node (left becomes the new tree)
            left = Ast.Expr{ .binary = .{ .left = left_ptr, .operator = operator.type, .right = right_ptr } };
        }

        return left;
    }

    fn parsePrimary(self: *Parser) !Ast.Expr {
        // --- Otherwise consume next token normally
        const token = self.consume();

        return switch (token.type) {
            .NUMBER => Ast.Expr{ .literal = token.literal.? },
            .STRING => Ast.Expr{ .literal = token.literal.? },
            .BOOLEAN => Ast.Expr{ .literal = token.literal.? },
            .NONE => Ast.Expr{ .literal = token.literal.? },
            .IDENTIFIER => Ast.Expr{ .identifier = token.lexeme },

            else => {
                //errors.report(token.line, "parse", "Unexpected token in primary expression");
                //std.debug.print("token: {any}\n", .{token});
                return error.UnexpectedToken;
            },
        };
    }

    // -------------------------------------------------------------
    // Utility functions
    // -------------------------------------------------------------
    fn parseTypeName(self: *Parser, name: []const u8) !Type {
        _ = self;
        if (std.mem.eql(u8, name, "number")) return .number;
        if (std.mem.eql(u8, name, "string")) return .string;
        if (std.mem.eql(u8, name, "boolean")) return .boolean;
        if (std.mem.eql(u8, name, "none")) return .none;

        //errors.report(self.peek().line, "parse", "Unknown type name");
        return error.UnknownType;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.peek().type == .NEWLINE) {
            _ = self.consume();
        }
    }

    fn match(self: *Parser, t: TokenType) bool {
        if (!self.isAtEnd() and self.peek().type == t) {
            _ = self.consume();
            return true;
        }
        return false;
    }

    fn consume(self: *Parser) Token {
        if (!self.isAtEnd()) self.current += 1;

        return self.tokens[self.current - 1];
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.current];
    }

    fn isAtEnd(self: *Parser) bool {
        return self.peek().type == .EOF;
    }
};

test "parse multiplication - manual tokens" {
    const allocator = testing.allocator;

    const tokens = [_]Token{
        Token{ .type = .IDENTIFIER, .lexeme = "x", .literal = null, .line = 1, .column = 1 },
        Token{ .type = .COLON_EQUAL, .lexeme = ":=", .literal = null, .line = 1, .column = 3 },
        Token{ .type = .NUMBER, .lexeme = "3", .literal = .{ .number = 3.0 }, .line = 1, .column = 6 },
        Token{ .type = .STAR, .lexeme = "*", .literal = null, .line = 1, .column = 8 },
        Token{ .type = .NUMBER, .lexeme = "4", .literal = .{ .number = 4.0 }, .line = 1, .column = 10 },
        Token{ .type = .EOF, .lexeme = "", .literal = null, .line = 1, .column = 11 },
    };

    var parser = try Parser.init(&tokens, allocator);
    var program = try parser.parse(); // Changed: var instead of const
    defer parser.deinit();
    defer program.deinit(); // ADD THIS LINE - frees the AST

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

test "parser deinit after toOwnedSlice" {
    const allocator = testing.allocator;

    const tokens = [_]Token{
        Token{ .type = .NUMBER, .lexeme = "42", .literal = .{ .number = 42.0 }, .line = 1, .column = 1 },
        Token{ .type = .EOF, .lexeme = "", .literal = null, .line = 1, .column = 3 },
    };

    var parser = try Parser.init(&tokens, allocator);
    var program = try parser.parse();

    // DON'T call parser.deinit()
    // defer parser.deinit();  ← Comment this out
    defer program.deinit();

    // Run with: zig test src/parser.zig
}
