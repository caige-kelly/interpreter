const std = @import("std");
const errors = @import("./error.zig");
const _scanner = @import("./scanner.zig").Scanner;

var stdout = std.fs.File.stdout().writer(&.{});
const w = &stdout.interface;

pub fn main() !void {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    switch (args.len) {
        1 => try runPrompt(),
        2 => try runFile(args[1]),
        else => {
            try w.print("Usage: zlox [script]\n", .{});
            try w.flush();
        },
    }
}

fn runFile(path: []const u8) !void {
    // Initialize the general purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Read the file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();

    // Fail if file larger than 2 GiB
    if (stat.size > 2147483648) {
        return error.FileTooLarge;
    }

    const allocator = gpa.allocator();
    const bytes = try allocator.alloc(u8, stat.size);

    _ = file.read(bytes) catch {
        allocator.free(bytes);
        return error.FileReadError;
    };

    try run(bytes);

    allocator.free(bytes);
}

fn runPrompt() !void {
    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    while (true) {
        try w.print("lox> ", .{});
        try w.flush();

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

    var scanner = try _scanner.init(source, gpa.allocator());
    defer _ = scanner.deinit();

    while (!scanner.isAtEnd()) {
        try scanner.scanTokens();
    }

    for (scanner.tokens.items) |token| {
        try w.print("{any}\n", .{token});
        try w.flush();
    }
}
