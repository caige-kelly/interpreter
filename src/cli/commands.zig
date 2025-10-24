const std = @import("std");
const exec = @import("exec.zig");
const repl = @import("repl.zig");
const version = @import("version.zig");

pub const execCommand = exec.run;
pub const replCommand = repl.run;
pub const versionCommand = version.run;
