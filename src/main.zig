const std = @import("std");
const Scanner = @import("./scanner.zig").Scanner;

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var scanner = try Scanner.init(source, gpa.allocator());
    defer _ = scanner.deinit();

    const tokens = try scanner.scanTokens();

    var stdout = std.fs.File.stdout().writer(&.{});
    var w = &stdout.interface;

    for (tokens) |token| {
        try w.print("{{ type = .{s}, lexeme = '{s}', literal = '{s}', line = {d}, column = {d} }}\n",
         .{@tagName(token.type), token.lexeme, token.literal, token.line, token.column});
    }
}
