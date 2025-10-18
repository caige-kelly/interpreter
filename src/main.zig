const std = @import("std");
const Lexer = @import("./lexer.zig").Lexer;
const Parser = @import("./parser.zig").Parser;
const Token = @import("./token.zig").Token;
const Ast = @import("./ast.zig");
const Evaluator = @import("./evaluator.zig").Evaluator;
const EvalConfig = @import("./evaluator.zig").EvalConfig;
const EvalResult = @import("./evaluator.zig").EvalResult;

const max_size: usize = 2 * 1024 * 1024 * 1024; // 2 GiB

pub fn main() !void {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator.allocator());
    defer _ = arena.deinit();

    // Read file
    const source = try std.fs.cwd().readFileAlloc(arena.allocator(), "docs/test.ripple", max_size);

    // 1. Lex
    var lexer = try Lexer.init(source, arena.allocator());
    const tokens = try lexer.scanTokens();

    // 2. Parse
    var parser = Parser.init(tokens, arena.allocator());
    const program = try parser.parse();

    // 3. Evaluate ← NEW!
    const eval_config = EvalConfig{ .enable_trace = true };
    var evaluator = try Evaluator.init(arena.allocator(), eval_config);
    const result = try evaluator.evaluate(program);

    const trace = evaluator.get_trace();

    // 4. Print result
    for (trace) |t| {
        std.debug.print("Trace: ", .{});
        switch (t.result) {
            .number => |n| std.debug.print("{d}\n", .{n}),
            .string => |s| std.debug.print("\"{s}\"\n", .{s}),
            .boolean => |b| std.debug.print("{}\n", .{b}),
            .none => std.debug.print("  none\n", .{}),
        }
    }

    std.debug.print("Result: ", .{});
    switch (result) {
        .number => |n| std.debug.print("{d}\n", .{n}),
        .string => |s| std.debug.print("\"{s}\"\n", .{s}),
        .boolean => |b| std.debug.print("{}\n", .{b}),
        .none => std.debug.print("none\n", .{}),
    }
}

pub fn printTokens(tokens: []const Token) void {
    std.debug.print("\n=== TOKENS ===\n", .{});
    for (tokens, 0..) |token, i| {
        std.debug.print("[{d}] {s:<15} '{s}'\n", .{
            i,
            @tagName(token.type),
            token.lexeme,
        });
    }
    std.debug.print("=== END TOKENS ===\n\n", .{});
}

pub fn printAst(program: Ast.Program) void {
    std.debug.print("\n=== AST ===\n", .{});
    for (program.expressions, 0..) |expr, i| {
        std.debug.print("[{d}] ", .{i});
        printExpr(expr, 0);
    }
    std.debug.print("=== END AST ===\n\n", .{});
}

fn printExpr(expr: Ast.Expr, indent: usize) void {
    const spaces = "                                        ";
    const prefix = spaces[0..@min(indent, spaces.len)];

    switch (expr) {
        .assignment => |a| {
            std.debug.print("{s}Assignment: '{s}'", .{ prefix, a.name });
            if (a.type) |t| {
                std.debug.print(" (type: {s})", .{@tagName(t)});
            }
            std.debug.print("\n", .{});
            std.debug.print("{s}  value:\n", .{prefix});
            printExpr(a.value.*, indent + 4);
        },

        .literal => |lit| {
            std.debug.print("{s}Literal: ", .{prefix});
            switch (lit) {
                .number => |n| std.debug.print("{d}\n", .{n}),
                .string => |s| std.debug.print("\"{s}\"\n", .{s}),
                .boolean => |b| std.debug.print("{}\n", .{b}),
                .none => std.debug.print("none\n", .{}),
            }
        },

        .identifier => |name| {
            std.debug.print("{s}Identifier: '{s}'\n", .{ prefix, name });
        },
        else => {},

        // Add other cases as you implement them:
        // .binary => |b| { ... },
        // .call => |c| { ... },
        // .lambda => |l| { ... },
        // etc.
    }
}
