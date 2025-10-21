const std = @import("std");

pub const VERSION = "0.1.0";

pub fn run() !void {
    std.debug.print("rvm version {s}\n", .{VERSION});
}
