const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Ast = @import("ast.zig");
const errors = @import("error.zig");

pub const ParseError = error{ UnexpectedToken, InvalidAssignmentTarget, ExpectedToken, NoMatchFound, OutOfMemory };

/// Parser: turns a token stream into an abstract syntax tree (AST)
/// Implements full precedence hierarchy (lowest → highest):
///   assignment → or → and → pipe → call → try → primary
///
/// Meaning:
///   - assignment (=) binds loosest; it wraps the full right-hand expression
///   - or        : tolerant fallback (if left is none, evaluate right)
///   - and       : tolerant sequencing (if left is present, evaluate right)
///   - pipe (|>) : pipeline composition (pass result of left into right)
///   - call      : function invocation and argument application
///   - try       : result unwrapping or error propagation
///   - primary   : literals, identifiers, lists, maps, lambdas, etc.
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
        const expr = try self.parseOr();

        if (self.match(.COLON_EQUAL)) {
            if (self.peek().type == .NEWLINE) {
                _ = self.advance();
            }

            const value = try self.parseOr();
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

    fn parseOr(self: *Parser) !Ast.Expr {
        var expr = try self.parseThen();

        while (self.match(.OR)) {
            while (self.check(.NEWLINE)) _ = self.advance();
            const right = try self.parseThen();

            const lp = try self.allocator.create(Ast.Expr);
            lp.* = expr;
            const rp = try self.allocator.create(Ast.Expr);
            rp.* = right;

            expr = Ast.Expr{ .or_expr = .{ .left = lp, .right = rp } };
        }

        return expr;
    }

    fn parseThen(self: *Parser) !Ast.Expr {
        var expr = try self.parsePipe();

        while (self.match(.THEN)) {
            while (self.check(.NEWLINE)) _ = self.advance();
            const right = try self.parsePipe();

            const lp = try self.allocator.create(Ast.Expr);
            lp.* = expr;
            const rp = try self.allocator.create(Ast.Expr);
            rp.* = right;

            expr = Ast.Expr{ .then_expr = .{ .left = lp, .right = rp } };
        }

        return expr;
    }

    fn parsePipe(self: *Parser) !Ast.Expr {
        var expr = try self.parseBinary();

        while (self.match(.PIPE)) {
            self.skipNewlines();

            const left_ptr = try self.allocator.create(Ast.Expr);
            left_ptr.* = expr;

            var right: Ast.Expr = undefined;

            if (self.check(.TAP)) {
                right = try self.parseTapStage(left_ptr);
            } else {
                right = try self.parseExpression();

                const rp = try self.allocator.create(Ast.Expr);
                rp.* = right;

                right = Ast.Expr{ .pipe = .{ .left = left_ptr, .right = rp } };
            }

            expr = right;
        }

        return expr;
    }

    fn parseTapStage(self: *Parser, left: *Ast.Expr) !Ast.Expr {
        _ = try self.expect(.TAP);
        self.skipNewlines();

        var bindings = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        while (!self.check(.ARROW)) {
            const t = try self.expect(.IDENTIFIER);
            try bindings.append(self.allocator, t.lexeme);
            if (!self.match(.COMMA)) break;
            self.skipNewlines();
        }

        _ = try self.expect(.ARROW);
        self.skipNewlines();

        const right = try self.parseExpression();

        const lp = try self.allocator.create(Ast.Expr);
        lp.* = left.*;
        const rp = try self.allocator.create(Ast.Expr);
        rp.* = right;

        return Ast.Expr{
            .tap_expr = .{
                .left = lp,
                .binding = try bindings.toOwnedSlice(self.allocator),
                .right = rp,
            },
        };
    }

    fn parseBinary(self: *Parser) !Ast.Expr {
        var expr = try self.parseCall();

        while (self.isBinaryOperator(self.peek().type)) {
            const op = self.advance();
            const right = try self.parseCall();

            const lp = try self.allocator.create(Ast.Expr);
            lp.* = expr;
            const rp = try self.allocator.create(Ast.Expr);
            rp.* = right;

            expr = Ast.Expr{
                .binary = .{
                    .left = lp,
                    .operator = op.type,
                    .right = rp,
                },
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
        _ = try self.expect(.MATCH);

        // Optional value before '->'
        var value_expr: Ast.Expr = undefined;

        if (self.check(.ARROW)) {
            // No explicit value — take it from the left-hand side of a pipe
            value_expr = Ast.Expr{ .identifier = "_pipe_input" };
            _ = self.advance(); // consume the arrow
        } else {
            // Explicit value provided
            value_expr = try self.parseOr(); // not full parseExpression
            _ = try self.expect(.ARROW);
        }

        var branches = try std.ArrayList(Ast.MatchBranch).initCapacity(self.allocator, 4);

        while (!self.check(.EOF)) {
            while (self.check(.NEWLINE) or self.check(.COMMA)) _ = self.advance();
            if (self.check(.EOF)) break;
            if (self.peek().type != .IDENTIFIER) break;

            const pattern_tok = self.advance();
            const pattern = pattern_tok.lexeme;

            var bindings = try std.ArrayList([]const u8).initCapacity(self.allocator, 2);
            while (!self.check(.ARROW)) {
                const b = try self.expect(.IDENTIFIER);
                try bindings.append(self.allocator, b.lexeme);
            }
            _ = try self.expect(.ARROW);

            const branch_expr = try self.parseExpression();
            const branch_ptr = try self.allocator.create(Ast.Expr);
            branch_ptr.* = branch_expr;

            try branches.append(self.allocator, Ast.MatchBranch{
                .pattern = pattern,
                .binding = try bindings.toOwnedSlice(self.allocator),
                .expr = branch_ptr,
            });

            _ = self.match(.NEWLINE);
            _ = self.match(.COMMA);
        }

        const value_ptr = try self.allocator.create(Ast.Expr);
        value_ptr.* = value_expr;

        return Ast.Expr{
            .match_expr = .{
                .value = value_ptr,
                .branches = try branches.toOwnedSlice(self.allocator),
            },
        };
    }

    fn parseLambda(self: *Parser) !Ast.Expr {
        var params = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);

        // Parse comma-separated identifiers until '->'
        while (!self.check(.ARROW)) {
            const t = try self.expect(.IDENTIFIER);
            try params.append(self.allocator, t.lexeme);

            if (self.match(.COMMA)) continue;
            if (self.check(.ARROW)) break;

            // Anything else here is a syntax error
            params.deinit(self.allocator);
            errors.report(self.peek().line, "parse", "Expected ',' or '->' in lambda parameters");
            return error.ExpectedToken;
        }

        _ = try self.expect(.ARROW);
        const body_expr = try self.parseExpression();

        const body_ptr = try self.allocator.create(Ast.Expr);
        body_ptr.* = body_expr;
        const param_slice = try params.toOwnedSlice(self.allocator);

        return Ast.Expr{
            .lambda = .{
                .params = param_slice,
                .body = body_ptr,
            },
        };
    }

    fn parsePrimary(self: *Parser) !Ast.Expr {
        // --- Check for lambda first, because it starts with IDENTIFIER(s)
        if (self.looksLikeLambda()) {
            return try self.parseLambda();
        }

        // --- Otherwise consume next token normally
        const token = self.advance();

        return switch (token.type) {
            .NUMBER => {
                if (token.literal) |lit| {
                    switch (lit) {
                        .number => |num| {
                            switch (num) {
                                .int => |i| return Ast.Expr{ .literal = .{ .number = .{ .int = i } } },
                                .float => |f| return Ast.Expr{ .literal = .{ .number = .{ .float = f } } },
                            }
                        },
                        else => {},
                    }
                }
                return Ast.Expr{ .literal = .{ .number = .{ .int = 0 } } };
            },
            .STRING => Ast.Expr{ .literal = .{ .string = token.getSLiteral().? } },
            .BOOLEAN => {
                if (token.literal) |lit| {
                    if (lit == .boolean) {
                        return Ast.Expr{ .literal = .{ .boolean = lit.boolean } };
                    }
                }
                return Ast.Expr{ .literal = .{ .boolean = false } };
            },
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

            .LEFT_BRACE => {
                // { key: value, ... }
                var entries = try std.ArrayList(Ast.MapPair).initCapacity(self.allocator, 0);

                // Skip any newlines after '{'
                while (self.check(.NEWLINE)) _ = self.advance();

                // Empty map "{}"
                if (self.check(.RIGHT_BRACE)) {
                    _ = self.advance();
                    const pairs = try entries.toOwnedSlice(self.allocator);
                    return Ast.Expr{  .map = .{ .pairs = pairs}  };
                }

                while (true) {
                    while (self.check(.NEWLINE)) _ = self.advance();

                    // --- key
                    const key_tok = self.peek();
                    if (self.isAtEnd()) {
                        entries.deinit(self.allocator);
                        errors.report(key_tok.line, "parse", "Unterminated map literal (missing '}')");
                        return error.ExpectedToken;
                    }
                    if (key_tok.type != .IDENTIFIER and key_tok.type != .STRING) {
                        entries.deinit(self.allocator);
                        errors.report(key_tok.line, "parse", "Expected identifier or string key in map");
                        return error.UnexpectedToken;
                    }
                    _ = self.advance();

                    // --- colon
                    _ = try self.expect(.COLON);

                    // --- value expression
                    const value_expr = try self.parseExpression();
                    const value_ptr = try self.allocator.create(Ast.Expr);
                    value_ptr.* = value_expr;

                    // Store pair
                    const entry = Ast.MapPair{
                        .key = key_tok.lexeme,
                        .value = value_ptr.*,
                    };
                    try entries.append(self.allocator, entry);

                    // --- separators and newlines
                    while (self.check(.NEWLINE)) _ = self.advance();

                    if (self.match(.COMMA)) {
                        while (self.check(.NEWLINE)) _ = self.advance();
                        if (self.check(.RIGHT_BRACE)) {
                            _ = self.advance();
                            break;
                        }
                        continue;
                    }

                    if (self.check(.RIGHT_BRACE)) {
                        _ = self.advance();
                        break;
                    }

                    if (self.isAtEnd()) {
                        entries.deinit(self.allocator);
                        errors.report(key_tok.line, "parse", "Unterminated map literal (missing '}')");
                        return error.ExpectedToken;
                    }

                    entries.deinit(self.allocator);
                    errors.report(self.peek().line, "parse", "Expected ',' or '}' in map literal");
                    return error.ExpectedToken;
                }

                const pairs = try entries.toOwnedSlice(self.allocator);
                return Ast.Expr{ .map = .{ .pairs = pairs }};
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
                    return Ast.Expr{  .list = .{ .elements = items }};
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
                return Ast.Expr{ .list = .{ .elements =  items }};
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
            .IDENTIFIER, .STRING, .NUMBER, .AT, .HASH, .LEFT_BRACE, .LEFT_BRACKET, => true,
            else => false,
        };
    }

    fn isBinaryOperator(self: *Parser, t: TokenType) bool {
        _ = self;
        return switch (t) {
            .PLUS, .MINUS, .STAR, .SLASH, .GREATER, .GREATER_EQUAL, .LESS, .LESS_EQUAL, .EQUAL_EQUAL, .BANG_EQUAL => true,
            else => false,
        };
    }

    fn looksLikeLambda(self: *Parser) bool {
        // scan ahead for '->' after identifiers and commas
        var i: usize = self.current;
        var seen_ident = false;

        while (i < self.tokens.len) {
            const t = self.tokens[i].type;
            if (t == .IDENTIFIER) {
                seen_ident = true;
                i += 1;
                continue;
            }
            if (t == .COMMA) {
                i += 1;
                continue;
            }
            return seen_ident and t == .ARROW;
        }
        return false;
    }

    fn scanNumber(self: *ParseError) void {
        const start = self.current;
        const start_col = self.column;

        while (!self.isAtEnd() and self.isDigit(self.peek())) {
            self.advance();
        }

        if (!self.isAtEnd() and self.peek() == '.' and self.isDigit(self.peekNext())) {
            self.advance();
            while (!self.isAtEnd() and self.isDigit(self.peek())) {
                self.advance();
            }
        }

        const lexeme = self.source[start..self.current];

        // Try to parse as int first
        if (std.mem.indexOf(u8, lexeme, ".") == null) {
            if (std.fmt.parseInt(i64, lexeme, 10)) |int_val| {
                self.tokens.append(.{
                    .type = .NUMBER,
                    .lexeme = lexeme,
                    .line = self.line,
                    .column = start_col,
                    .literal = .{ .number = .{ .int = int_val } },
                }) catch unreachable;
                return;
            } else |_| {}
        }

        // Parse as float
        const float_val = std.fmt.parseFloat(f64, lexeme) catch 0;
        self.tokens.append(.{
            .type = .NUMBER,
            .lexeme = lexeme,
            .line = self.line,
            .column = start_col,
            .literal = .{ .number = .{ .float = float_val } },
        }) catch unreachable;
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
    fn skipNewlines(self: *Parser) void {
        while (self.check(.NEWLINE)) _ = self.advance();
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
