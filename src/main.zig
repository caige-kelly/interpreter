const std = @import("std");
const print = std.debug.print;


const Scanner = struct {
    source: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(source: []const u8, allocator: std.mem.Allocator) Scanner {
        return Scanner{ .source = source, .allocator = allocator };
    }

    pub fn scanTokens(self: *Scanner) []const u8 {
        return self.source;
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
        try run_prompt();
    }
}

fn run_file(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const buffer: []u8 = undefined;
    var reader = file.reader(buffer);
    const interface = &reader.interface;

    const file_content = interface.takeDelimiterExclusive('0') catch |err| switch (err) {
        error.EndOfStream => "",
        else => return err,
    };

    try run(file_content);
}

fn run_prompt() !void {
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

            try run(line);
        }
}

fn run(source: []const u8) !void {
    // Initialize the general purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const bytes = try allocator.alloc(u8, 4096);

    var scanner = Scanner.init(source, allocator);
    defer scanner.deinit();

    const tokens = scanner.scanTokens();
    print("Tokens: {s}\n", .{tokens});

    for (tokens) |token| {
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.print("{d}\n", .{token});
        try stdout.flush();
    }

    allocator.free(bytes);
    defer _ = gpa.deinit();
    return;
}
