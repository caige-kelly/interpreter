const std = @import("std");

pub var hadError: bool = false;

pub const RuntimeError = error{
    UnknownVariable,
    NoMatch,
    TypeMismatch,
    InvalidOperation,
};

pub fn report(line: usize, where: []const u8, message: []const u8) void {
    // Unbuffered: pass an empty slice
    var w_impl = std.fs.File.stderr().writer(&.{});
    const w = &w_impl.interface;

    w.print("[line {d}] Error {s}: {s}\n", .{ line, where, message }) catch std.process.exit(5);
    w.flush() catch std.process.exit(5);

    hadError = true;
}
