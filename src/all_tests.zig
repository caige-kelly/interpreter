// tests.zig
const std = @import("std");

test {
    _ = @import("supervisor.zig");
    _ = @import("evaluator.zig");
    _ = @import("parser.zig");
    _ = @import("lexer.zig");
    // etc.
}
