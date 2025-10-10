const std = @import("std");

pub var hadError: bool = false;

pub fn report(line: usize, where_: []const u8, message: []const u8) !void {
    // Obtain a stderr writer
    var stderr_file = std.fs.File.stderr();
    var stderr_buf: [512]u8 = undefined; // buffer for formatting
    var stderr_writer = stderr_file.writer(&stderr_buf);
    const w = &stderr_writer.interface; // get *std.Io.Writer

    try w.print("[line {d}] Error {s}: {s}\n", .{ line, where_, message });
    try w.flush(); // flush buffered writer if necessary

    hadError = true;
}
