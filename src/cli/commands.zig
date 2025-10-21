const std = @import("std");
const exec = @import("exec.zig");
const version = @import("version.zig");

pub const execCommand = exec.run;
pub const versionCommand = version.run;
