const std = @import("std");
const commands = @import("commands");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    // Get command
    const command = args.next() orelse {
        printUsage();
        return;
    };

    // Dispatch to command handler
    if (std.mem.eql(u8, command, "exec")) {
        try commands.execCommand(allocator, &args);
    } else if (std.mem.eql(u8, command, "version")) {
        try commands.versionCommand();
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else if (std.mem.eql(u8, command, "repl")) {
        try commands.replCommand(allocator);
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
        std.process.exit(1);
    }
}

fn printUsage() void {
    const usage =
        \\Usage: rvm <command> [options]
        \\
        \\Commands:
        \\  exec <script>      Execute a Ripple script with supervision
        \\  version            Show rvm version
        \\  help               Show this help message
        \\
        \\Examples:
        \\  rvm exec backup.rip
        \\  rvm exec backup.rip --trace --timeout 30000
        \\  rvm version
        \\
        \\For more information on a command:
        \\  rvm <command> --help
        \\
    ;
    std.debug.print("{s}", .{usage});
}
