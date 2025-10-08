const std = @import("std");
const token = @import("tokentype.zig");

const Scanner = struct { source: []const u8, tokens: []const token.Token };
