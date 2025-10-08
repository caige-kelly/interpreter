const std = @import("std");
const print = std.debug.print;


const Scanner = struct {
    source: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(source: []const u8, allocator: std.mem.Allocator) Scanner {
        return Scanner{ .source = source, .allocator = allocator };
    }

    pub fn scanTokens(self: *Scanner) ![]const u8 {
        _ = self;
        return "no-tokens-yet";
    }

    pub fn deinit(self: *Scanner) void {
        _ = self;
    }
};

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
        try run_file(args[1]);
    } else {
        try run_prompt(allocator);
    }
}

fn run_file(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buffer: [4096]u8 = undefined;
    try file.seekTo(0);
    const bytesRead = try file.readAll(&buffer);

    std.debug.print("Running file: {s}\n", .{path});
    std.debug.print("File contents:\n{s}\n", .{buffer[0..bytesRead]});
}

fn run(source: []const u8, allocator: std.mem.Allocator) !void {
    // Initialize scanner
    var scanner = Scanner.init(source, allocator);

    // Get tokens
    const tokens = try scanner.scanTokens();

    for (tokens) |token| {
        var buf: [1024]u8 = undefined;
        var stdout_file = std.fs.File.stdout();
        var writer = stdout_file.writer(&buf).interface;
        try writer.print("{d}\n", .{token});
    }

    scanner.deinit();
}

fn run_prompt(allocator: std.mem.Allocator) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;
        
        while (true) {
            try stdout.print("lox> ", .{});
            try stdout.flush();

            const line = stdin.takeDelimiterExclusive('\n')  catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };

            if (line.len == 0) continue;

            try run(line, allocator);
        }
}