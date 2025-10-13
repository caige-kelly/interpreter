const std = @import("std");
const Lexer = @import("./lexer.zig").Lexer;
const Parser = @import("./parser.zig").Parser;
const Ast = @import("./ast.zig");
const eval = @import("./parser.zig");

const max_size = 2 * 1024 * 1024 * 1024; // 2 GiB

pub fn main() !void {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout = std.fs.File.stdout().writer(&.{});
    var w = &stdout.interface;

    switch (args.len) {
        1 => try runPrompt(),
        2 => try runFile(args[1]),
        else => {
            try w.print("Usage: zlox [script]\n", .{});
        },
    }
}

fn runFile(path: []const u8) !void {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    const stat = try f.stat();

    if (stat.size > max_size) {
        return error.FileTooLarge;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const bytes = try allocator.alloc(u8, stat.size);
    defer allocator.free(bytes);

    _ = try f.readAll(bytes);

    try run(bytes);
}

fn runPrompt() !void {
    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    var stdout = std.fs.File.stdout().writer(&.{});
    const w = &stdout.interface;

    while (true) {
        try w.print("lox> ", .{});

        const line = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        if (line.len == 0) continue;

        try run(line);
    }
}

fn run(source: []const u8) !void {
    // init general allocator for arenas
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // ------ Phase 1: Scan ---------
    var scan_arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer scan_arena.deinit();

    var lex = try Lexer.init(source, scan_arena.allocator());

    const tokens = try lex.scanTokens();

    // ---------- Phase 2: Parse ---------
    var parse_arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer parse_arena.deinit();

    var parser = Parser.init(tokens, parse_arena.allocator());
    const exprs = try parser.parse();

    // --------- Phase 3: Convert ---------
    var eval_arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer eval_arena.deinit();

    for (exprs) |*expr| {
        const e = try eval.converter(expr, eval_arena.allocator());
        Ast.debugPrint(e.*, 0);
    }
}
