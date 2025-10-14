const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Ast = @import("ast.zig");
const errors = @import("error.zig");

pub const ParseError = error{ UnexpectedToken, InvalidAssignmentTarget, ExpectedToken, NoMatchFound, OutOfMemory };

/// Parser: turns a token stream into an abstract syntax tree (AST)
/// Implements precedence: assignment → pipe → call → try → primary
pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    current: usize = 0,

    // -------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------
    pub fn init(tokens: []const Token, allocator: std.mem.Allocator) Parser {
        return .{
            .tokens = tokens,
            .allocator = allocator,
        };
    }

    // -------------------------------------------------------------
    // Entry point
    // -------------------------------------------------------------
    pub fn parse(self: *Parser) ![]Ast.Expr {
        var exprs = try std.ArrayList(Ast.Expr).initCapacity(self.allocator, 16);

        while (!self.isAtEnd()) {
            // Skip newlines and whitespace
            while (self.check(.NEWLINE)) _ = self.advance();
            if (self.isAtEnd()) break;

            const expr = try self.parseExpression();
            try exprs.append(self.allocator, expr);

            // Consume continuation newlines (for multi-line pipes)
            while (self.check(.NEWLINE)) {
                _ = self.advance();
                if (!self.check(.PIPE)) break;
            }
        }

        return exprs.toOwnedSlice(self.allocator);
    }

    // -------------------------------------------------------------
    // Expression parsing (top-down precedence)
    // -------------------------------------------------------------
    fn parseExpression(self: *Parser) ParseError!Ast.Expr {
        const tok = self.peek();
        switch (tok.type) {
            .TRY => return try self.parseTry(),
            .MATCH => return try self.parseMatch(),
            else => return try self.parseAssignment(),
        }
    }

    fn parseAssignment(self: *Parser) !Ast.Expr {
        const expr = try self.parsePipe();

        if (self.match(.EQUAL)) {
            if (self.peek().type == .NEWLINE) {
                _ = self.advance();
            }

            const value = try self.parsePipe();
            switch (expr) {
                .identifier => |name| {
                    const value_ptr = try self.allocator.create(Ast.Expr);
                    value_ptr.* = value;
                    return Ast.Expr{
                        .assign = .{
                            .name = name,
                            .value = value_ptr,
                        },
                    };
                },
                else => {
                    errors.report(self.peek().line, "parse", "Invalid assignment target");
                    return error.InvalidAssignmentTarget;
                },
            }
        }

        return expr;
    }

    fn parsePipe(self: *Parser) !Ast.Expr {
        var expr = try self.parseCall();

        while (self.match(.PIPE)) {
            const right = try self.parseCall();

            const lp = try self.allocator.create(Ast.Expr);
            lp.* = expr;

            const rp = try self.allocator.create(Ast.Expr);
            rp.* = right;

            expr = Ast.Expr{ .pipe = .{ .left = lp, .right = rp } };
        }

        return expr;
    }

    fn parseCall(self: *Parser) !Ast.Expr {
        var expr = try self.parseTry();

        while (self.nextLooksLikeArg()) {
            const arg = try self.parseTry();

            const callee_ptr = try self.allocator.create(Ast.Expr);
            callee_ptr.* = expr;

            var args = try std.ArrayList(Ast.Expr).initCapacity(self.allocator, 1);
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

    fn parseMatch(self: *Parser) !Ast.Expr {
        // consume the 'match' keyword
        _ = try self.expect(.MATCH);

        // parse the value being matched
        const value_expr = try self.parseExpression();
        _ = try self.expect(.ARROW); // expect the '->' after value

        var branches = try std.ArrayList(Ast.MatchBranch).initCapacity(self.allocator, 4);

        while (!self.check(.EOF)) {
            // skip whitespace/newlines/commas between branches
            while (self.check(.NEWLINE) or self.check(.COMMA)) {
                _ = self.advance();
            }
            if (self.check(.EOF)) break;
            const t = self.peek().type;

            // const is_stop =
            //     t == .ARROW or // saw '->' without a pattern; don't consume it
            //     t == .RIGHT_PAREN or // defensive if a prior parse left us here
            //     t == .RIGHT_BRACE or // if you ever add block forms
            //     t == .EOF;

            if (t != .IDENTIFIER) break;

            // --- parse the pattern (ok, err, etc.)
            const pattern_tok = self.advance();
            const pattern = pattern_tok.lexeme;

            // optional binding in parentheses: ok(value) / err(message)
            var binding: ?[]const u8 = null;
            if (self.match(.LEFT_PAREN)) {
                const bind_tok = self.consume(.IDENTIFIER, "expected binding name after '('");
                binding = bind_tok.lexeme;
                _ = try self.expect(.RIGHT_PAREN);
            }

            // --- expect the arrow for this branch
            _ = try self.expect(.ARROW);

            // --- parse the expression for this branch
            const branch_expr = try self.parseExpression();

            const branch_ptr = try self.allocator.create(Ast.Expr);
            branch_ptr.* = branch_expr;

            try branches.append(self.allocator, Ast.MatchBranch{
                .pattern = pattern,
                .binding = binding,
                .expr = branch_ptr,
            });

            // optional comma or newline before next branch
            _ = self.match(.NEWLINE);
            _ = self.match(.COMMA);
        }

        // wrap up match expression node
        const value_ptr = try self.allocator.create(Ast.Expr);
        value_ptr.* = value_expr;

        return Ast.Expr{
            .match_expr = .{
                .value = value_ptr,
                .branches = try branches.toOwnedSlice(self.allocator),
            },
        };
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
            .UNDERSCORE => Ast.Expr{ .identifier = token.lexeme },

            // Handle monadic identifiers: @Namespace.func
            .AT => {
                const ns = self.consume(.IDENTIFIER, "expected identifier after '@'");
                _ = self.consume(.DOT, "expected '.' after monad namespace");
                const func = self.consume(.IDENTIFIER, "expected function name after '.'");

                const full = try std.fmt.allocPrint(self.allocator, "@{s}.{s}", .{ ns.lexeme, func.lexeme });
                return Ast.Expr{ .identifier = full };
            },

            .HASH => {
                const ns = self.consume(.IDENTIFIER, "expected identifier after '#'");
                _ = self.consume(.DOT, "expected '.' after instrinsic namespace");
                const func = self.consume(.IDENTIFIER, "expected function name after '.'");

                const full = try std.fmt.allocPrint(self.allocator, "#{s}.{s}", .{ ns.lexeme, func.lexeme });
                return Ast.Expr{ .identifier = full };
            },

            .LEFT_BRACKET => {
                // [ <expr> ( , <expr> )* ,? ]
                var items_list = try std.ArrayList(Ast.Expr).initCapacity(self.allocator, 0);

                // Optional: eat any newlines right after '['
                while (self.check(.NEWLINE)) _ = self.advance();

                // Empty list: "[]"
                if (self.check(.RIGHT_BRACKET)) {
                    _ = self.advance(); // consume ']'
                    const items = try items_list.toOwnedSlice(self.allocator);
                    return Ast.Expr{ .literal = .{ .list = items } };
                }

                // Parse first and subsequent elements
                while (true) {
                    // Allow leading newlines before an element
                    while (self.check(.NEWLINE)) _ = self.advance();

                    const elem = try self.parseExpression();
                    try items_list.append(self.allocator, elem);

                    // Skip trailing newlines after the element
                    while (self.check(.NEWLINE)) _ = self.advance();

                    if (self.isAtEnd()) {
                        items_list.deinit(self.allocator);
                        errors.report(token.line, "parse", "Unterminated list literal (missing ']')");
                        return error.ExpectedToken;
                    }

                    // Trailing comma is allowed: [a, b,]
                    if (self.match(.COMMA)) {
                        // Consume any number of newlines after the comma
                        while (self.check(.NEWLINE)) _ = self.advance();

                        // If the next token is ']', that's a trailing comma — finish
                        if (self.check(.RIGHT_BRACKET)) {
                            _ = self.advance();
                            break;
                        }

                        if (self.isAtEnd()) {
                            items_list.deinit(self.allocator);
                            errors.report(token.line, "parse", "Unterminated list literal (missing ']')");
                            return error.ExpectedToken;
                        }

                        // Otherwise, loop to parse the next element
                        continue;
                    }

                    // No comma: expect closing bracket
                    _ = try self.expect(.RIGHT_BRACKET);
                    break;
                }

                const items = try items_list.toOwnedSlice(self.allocator);
                return Ast.Expr{ .literal = .{ .list = items } };
            },

            else => {
                errors.report(token.line, "parse", "Unexpected token in primary expression");
                std.debug.print("token: {any}\n", .{token});
                return error.UnexpectedToken;
            },
        };
    }

    // -------------------------------------------------------------
    // Utility functions
    // -------------------------------------------------------------
    fn match(self: *Parser, t: TokenType) bool {
        if (self.check(t)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, t: TokenType) !Token {
        if (self.check(t)) return self.advance();
        errors.report(self.peek().line, "parse", "Expected token");
        return error.ExpectedToken;
    }

    fn consume(self: *Parser, t: TokenType, msg: []const u8) Token {
        if (self.isAtEnd() or self.peek().type != t) {
            errors.report(self.peek().line, "parse", msg);
            return self.peek();
        }
        return self.advance();
    }

    fn nextLooksLikeArg(self: *Parser) bool {
        const next = self.peek();
        if (next.type == .NEWLINE) {
            _ = self.advance();
        }

        return switch (next.type) {
            .IDENTIFIER, .STRING, .NUMBER, .TRUE, .FALSE, .AT, .HASH, .LEFT_BRACE, .LEFT_BRACKET, .UNDERSCORE, .PLUS => true,
            else => false,
        };
    }

    fn check(self: *Parser, t: TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().type == t;
    }

    fn advance(self: *Parser) Token {
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

// -------------------------------------------------------------
// Desugaring Pass: converts pipes into function calls
// -------------------------------------------------------------
pub fn converter(expr: *const Ast.Expr, allocator: std.mem.Allocator) !*Ast.Expr {
    switch (expr.*) {
        .pipe => {
            const left_expr = try converter(expr.pipe.left, allocator);
            const right_expr = try converter(expr.pipe.right, allocator);

            const args_slice = try allocator.alloc(Ast.Expr, 1);
            args_slice[0] = left_expr.*;

            const call_node = try allocator.create(Ast.Expr);
            call_node.* = Ast.Expr{
                .call = .{
                    .callee = right_expr,
                    .args = args_slice,
                },
            };
            return call_node;
        },

        .call => {
            const callee = try converter(expr.call.callee, allocator);
            const args = try allocator.alloc(Ast.Expr, expr.call.args.len);

            for (expr.call.args, 0..) |*arg, i| {
                const darg = try converter(arg, allocator);
                args[i] = darg.*;
            }

            const new_expr = try allocator.create(Ast.Expr);
            new_expr.* = Ast.Expr{
                .call = .{
                    .callee = callee,
                    .args = args,
                },
            };
            return new_expr;
        },

        else => {
            const copy = try allocator.create(Ast.Expr);
            copy.* = expr.*;
            return copy;
        },
    }
}
