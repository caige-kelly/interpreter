pub const Process = @import("process.zig");
pub const Supervisor = @import("supervisor.zig");
pub const System = @import("system.zig");

test {
    _ = @import("process.zig");
    _ = @import("supervisor.zig");
    _ = @import("system.zig");
}
