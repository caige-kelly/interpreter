pub const Evaluator = @import("evaluator.zig");
pub const Environment = @import("environment.zig");
pub const Value = @import("value.zig");
pub const Result = @import("result.zig");

// These imports pull in the tests from all subfiles
test {
    _ = @import("evaluator.zig");
    _ = @import("environment.zig");
    _ = @import("value.zig");
    _ = @import("result.zig");
}
