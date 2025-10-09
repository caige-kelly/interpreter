const std = @import("std");
const _errors = @import("./errors.zig");
const _token = @import("./tokentype.zig");

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
        try run_file(args[1]);
    } else {
        try run_prompt();
    }
}

fn run_file(path: []const u8) !void {
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

        const line = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        if (line.len == 0) continue;

        try run(line);
    }
}

fn run(source: []const u8) !void {
    const _type = _token.TokenType;
    
    // Initialize the general purpose allocator for tokens I think
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const tokens = try allocator.alloc(_token.Token, 4096);

    var c: u8 = 0; //column position
    // var s: u8 = 0; //start position
    var l: u8 = 1; //line
    var t: u8 = 0; // some way to move token position forware

    while(c < source.len) {
        switch (source[c]) {
            40 => { tokens[t] = _token.Token{ .lexeme = source[c..c+1], .type = _type.LEFT_PAREN, .line = l, .column = c}; t += 1; },
            41 => { tokens[t] = _token.Token{ .lexeme = source[c..c+1], .type = _type.RIGHT_PAREN, .line = l, .column = c}; t += 1;},
            123 => { tokens[t] = _token.Token{ .lexeme = source[c..c+1], .type = _type.LEFT_BRACE, .line = l, .column = c}; t += 1;},
            125 => { tokens[t] = _token.Token{ .lexeme = source[c..c+1], .type = _type.RIGHT_BRACE, .line = l, .column = c}; t += 1;},
            44 => { tokens[t] = _token.Token{ .lexeme = source[c..c+1], .type = _type.COMMA, .line = l, .column = c}; t += 1;},
            46 => { tokens[t] = _token.Token{ .lexeme = source[c..c+1], .type = _type.DOT, .line = l, .column = c}; t += 1;},
            45 => { tokens[t] = _token.Token{ .lexeme = source[c..c+1], .type = _type.MINUS, .line = l, .column = c}; t += 1;},
            43 => { tokens[t] = _token.Token{ .lexeme = source[c..c+1], .type = _type.PLUS, .line = l, .column = c}; t += 1;},
            59 => { tokens[t] = _token.Token{ .lexeme = source[c..c+1], .type = _type.SEMICOLON, .line = l, .column = c}; t += 1;},
            42 => { tokens[t] = _token.Token{ .lexeme = source[c..c+1], .type = _type.STAR, .line = l, .column = c}; t += 1;},
            10 => { l += 1; c = 0; },
            else => {},
        }
        c += 1;
    }

    for (tokens[0..t]) |token| {
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.print("{any}\n", .{token});
        try stdout.flush();
    }

    allocator.free(tokens);
    return;
}
