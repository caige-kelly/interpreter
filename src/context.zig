const std = @import("std");
const Value = @import("value.zig").Value;

pub const Context = struct {
    allocator: std.mem.Allocator,
    vars: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .allocator = allocator,
            .vars = std.StringHashMap(Value).init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        self.vars.deinit();
    }

    /// Define or update a variable in the context
    pub fn set(self: *Context, name: []const u8, value: Value) !void {
        try self.vars.put(name, value);
    }

    /// Look up a variable by name
    pub fn get(self: *Context, name: []const u8) ?Value {
        return self.vars.get(name);
    }

    /// Check if variable exists
    pub fn contains(self: *Context, name: []const u8) bool {
        return self.vars.contains(name);
    }

    /// Debug print (optional helper)
    pub fn debug(self: *Context) void {
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            std.debug.print("{s} = {any}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
};
