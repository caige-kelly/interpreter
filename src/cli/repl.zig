const std = @import("std");
const evaluator = @import("../evaluator.zig");
const lexer = @import("../lexer.zig");
const parser = @import("../parser.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    // Buffered stdin reader -> std.Io.Reader
    var in_buf: [4096]u8 = undefined;
    var file_stdin_reader = std.fs.File.stdin().reader(&in_buf);
    const stdin: *std.Io.Reader = &file_stdin_reader.interface;

    // Buffered stdout writer -> std.Io.Writer
    var out_buf: [4096]u8 = undefined;
    var file_stdout_writer = std.fs.File.stdout().writer(&out_buf);
    const stdout: *std.Io.Writer = &file_stdout_writer.interface;

    try stdout.print("Ripple REPL (type 'exit' to quit)\n", .{});
    try stdout.flush();

    while (true) {
        try stdout.print("{s}", .{"> "});
        try stdout.flush();

        // Non-allocating line read (returns a view into the reader's buffer)
        const line = stdin.takeDelimiterExclusive('\n') catch |err| {
            if (err == error.EndOfStream) break;
            try stdout.print("read error: {s}\n", .{@errorName(err)});
            continue;
        };

        const trimmed = std.mem.trim(u8, line, " \r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "exit")) break;

        // Use an arena per line for tokens/AST/eval temporaries
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const tokens = lexer.tokenize(trimmed, arena.allocator()) catch |err| {
            try stdout.print("lexer error: {s}\n", .{@errorName(err)});
            try stdout.flush();
            continue;
        };

        var program = parser.parse(tokens, arena.allocator()) catch |err| {
            try stdout.print("parser error: {s}\n", .{@errorName(err)});
            try stdout.flush();
            continue;
        };
        defer program.deinit();

        var result = evaluator.evaluate(program, arena.allocator(), .{}) catch |err| {
            try stdout.print("runtime error: {s}\n", .{@errorName(err)});
            try stdout.flush();
            continue;
        };

        try result.print(stdout);
        try stdout.print("\n", .{});
        try stdout.flush();
    }

    try stdout.print("bye 👋\n", .{});
    try stdout.flush();
}
