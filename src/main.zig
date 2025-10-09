const std = @import("std");
const _errors = @import("./errors.zig");
const _scanner = @import("./scanner.zig").Scanner;

const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 3) {
        print("Usage: zlox [script]\n", .{});
        return;
    } else if (args.len == 2) {
        try runFile(args[1]);
    } else {
        try runPrompt();
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
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    while (true) {
        try stdout.print("lox> ", .{});
        try stdout.flush();

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
        print("{any}\n", .{token});
    }
}
