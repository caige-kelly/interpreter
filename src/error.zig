const std = @import("std");

pub var hadError: bool = false;

pub fn report(line: usize, where: []const u8, message: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const err_msg_size = message.len + where.len + line + 50;

    const allocator = gpa.allocator();
    const bytes = try allocator.alloc(u8, err_msg_size);

    var writer = std.fs.File.stderr().writer(bytes).interface;

    try writer.print("[line {any}] Error {s}: {s} \n", .{ line, where, message });
    try writer.flush();

    allocator.free(bytes);
}
