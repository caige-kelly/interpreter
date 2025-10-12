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

    pub fn parse(self: *Parser) ![]Ast.Expr {
        var expressions = try std.ArrayList(Ast.Expr).initCapacity(self.allocator, 0);

        while (!self.isAtEnd()) {
            if (self.match(.NEWLINE)) continue;

            const expr = try self.parseExpression();
            try expressions.append(self.allocator, expr);
        }

        return expressions.toOwnedSlice(self.allocator);
    }

    fn parseExpression(self: *Parser) !Ast.Expr {
        return self.parsePipe();
    }

    fn parsePipe(self: *Parser) !Ast.Expr {
        var expr = try self.parseCall();

        while (self.match(.PIPE)) {
            const right = try self.parseCall();
            const left_ptr = try self.allocator.create(Ast.Expr);
            left_ptr.* = expr;

            const right_ptr = try self.allocator.create(Ast.Expr);
            right_ptr.* = right;

            expr = Ast.Expr{
                .pipe = .{ .left = left_ptr, .right = right_ptr },
            };
        }

        return expr;
    }

    fn parseCall(self: *Parser) !Ast.Expr {
        var expr = try self.parseTry();

        while (self.nextLooksLikeArg()) {
            const arg = try self.parseTry();

            const callee_ptr = try self.allocator.create(Ast.Expr);
            callee_ptr.* = expr;

            var args = try std.ArrayList(Ast.Expr).initCapacity(self.allocator, 0);
            defer args.deinit(self.allocator);

            try args.append(self.allocator, arg);

            const arg_slice = try args.toOwnedSlice(self.allocator);

            expr = Ast.Expr{
                .call = .{
                    .callee = callee_ptr,
                    .args = arg_slice,
                },
            };
        }

        return expr;
    }

    fn parseTry(self: *Parser) !Ast.Expr {
        if (self.match(.TRY)) {
            const inner = try self.parsePrimary();
            const inner_ptr = try self.allocator.create(Ast.Expr);
            inner_ptr.* = inner;

            return Ast.Expr{
                .try_expr = .{ .expr = inner_ptr },
            };
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) !Ast.Expr {
        const token = self.advance();

        return switch (token.type) {
            .NUMBER => Ast.Expr{ .literal = .{ .number = token.getNLiteral().? } },
            .STRING => Ast.Expr{ .literal = .{ .string = token.getSLiteral().? } },
            .TRUE => Ast.Expr{ .literal = .{ .boolean = true } },
            .FALSE => Ast.Expr{ .literal = .{ .boolean = false } },
            .NONE => Ast.Expr{ .literal = .{ .none = {} } },
            .IDENTIFIER => Ast.Expr{ .identifier = token.lexeme },
            .AT => {
                const ns = self.consume(.IDENTIFIER, "expected identifier after '@'");
                _ = self.consume(.DOT, "expected '.' after monad namespace");
                const func = self.consume(.IDENTIFIER, "expected function name after '.'");

                // Build "@Namespace.func" into arena-owned memory
                const full = try std.fmt.allocPrint(self.allocator, "@{s}.{s}", .{ ns.lexeme, func.lexeme });
                return Ast.Expr{ .identifier = full };
            },
            else => {
                errors.report(token.line, "parse", "Unexpected token in primary expression");
                return error.UnexpectedToken;
            },
        };
    }

    // -------------------------------
    // Utility methods
    // -------------------------------

    fn nextLooksLikeArg(self: *Parser) bool {
        const next = self.peek();
        return switch (next.type) {
            .IDENTIFIER, .STRING, .NUMBER, .TRUE, .FALSE, .AT => true,
            else => false,
        };
    }

    fn match(self: *Parser, t: TokenType) bool {
        if (self.check(t)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn check(self: *Parser, t: TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().type == t;
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

    fn consume(self: *Parser, t: TokenType, msg: []const u8) Token {
        if (self.isAtEnd() or self.peek().type != t) {
            errors.report(self.peek().line, "parse", msg);
            return self.peek(); // you might prefer 'return error.UnexpectedToken'
        }
        return self.advance();
    }
};
