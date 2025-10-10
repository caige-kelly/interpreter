const std = @import("std");

pub var hadError: bool = false;

pub fn report(line: usize, where: []const u8, message: []const u8) !void {
    // Unbuffered: pass an empty slice
    var w_impl = std.fs.File.stderr().writer(&.{});
    const w = &w_impl.interface;

    try w.print("[line {d}] Error {s}: {s}\n", .{ line, where, message });
    try w.flush(); // still fine to call; it's cheap with an empty buffer

    hadError = true;
}
