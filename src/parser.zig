const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Ast = @import("ast.zig");
const errors = @import("error.zig");

pub const Parser = struct {
    tokens: []const Token,
    current: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(tokens: []const Token, allocator: std.mem.Allocator) Parser {
        return Parser{ .tokens = tokens, .allocator = allocator };
    }

    // Entry point: parse the full program
    pub fn parse(self: *Parser) ![]Ast.Expr {
        var expressions = try std.ArrayList(Ast.Expr).initCapacity(self.allocator, 0);

        while (!self.isAtEnd()) {
            const expr = try self.parseExpression();
            try expressions.append(self.allocator, expr);
        }

        return expressions.toOwnedSlice(self.allocator);
    }

    fn parseExpression(self: *Parser) !Ast.Expr {
        return self.parsePrimary(); // start small
    }

    fn parsePrimary(self: *Parser) !Ast.Expr {
        const token = self.advance();

        return switch (token.type) {
            .NUMBER => Ast.Expr{ .literal = .{ .number = token.getNLiteral().? } },
            .STRING => Ast.Expr{ .literal = .{ .string = token.getSLiteral().? } },
            .TRUE => Ast.Expr{ .literal = .{ .boolean = true } },
            .FALSE => Ast.Expr{ .literal = .{ .boolean = false } },
            .NONE => Ast.Expr{ .literal = .{ .none = {} } },
            else => {
                errors.report(token.line, "parse", "Unexpected token in primary expression");
                return error.UnexpectedToken;
            },
        };
    }

    fn advance(self: *Parser) Token {
        if (!self.isAtEnd()) self.current += 1;
        return self.tokens[self.current - 1];
    }

    fn isAtEnd(self: *Parser) bool {
        return self.peek().type == .EOF;
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.current];
    }
};
