const std = @import("std");

// Mock Value & Environment until we integrate with evaluator/runtime.
// We’re only testing structure here, not function dispatch.
pub const Value = union(enum) {
    none,
    namespace: *Namespace,
};

pub const Namespace = struct {
    name: []const u8,
};

pub const Environment = struct {
    table: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator) Environment {
        return Environment{ .table = std.StringHashMap(Value).init(allocator) };
    }

    pub fn deinit(self: *Environment) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .namespace => |ns| self.table.allocator.destroy(ns),
                else => {},
            }
        }
        self.table.deinit();
    }

    pub fn insert(self: *Environment, name: []const u8, value: Value) !void {
        try self.table.put(name, value);
    }

    pub fn get(self: *Environment, name: []const u8) ?Value {
        return self.table.get(name);
    }
};

// ---------------------------------------------------------------------
// Prelude loader
// ---------------------------------------------------------------------

pub fn loadPrelude(env: *Environment, allocator: std.mem.Allocator) !void {
    // Each namespace has a name for now; functions come later.
    const TaskNamespace = try allocator.create(Namespace);
    TaskNamespace.* = Namespace{ .name = "Task" };
    try env.insert("Task", Value{ .namespace = TaskNamespace });

    const ProcessNamespace = try allocator.create(Namespace);
    ProcessNamespace.* = Namespace{ .name = "Process" };
    try env.insert("Process", Value{ .namespace = ProcessNamespace });

    const SystemNamespace = try allocator.create(Namespace);
    SystemNamespace.* = Namespace{ .name = "System" };
    try env.insert("System", Value{ .namespace = SystemNamespace });
}

test "loadPrelude inserts System, Process, and Task namespaces" {
    const allocator = std.testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    try loadPrelude(&env, allocator);

    const system = env.get("System");
    const process = env.get("Process");
    const task = env.get("Task");

    try std.testing.expect(system != null);
    try std.testing.expect(process != null);
    try std.testing.expect(task != null);

    try std.testing.expect(system.?.namespace.name.len > 0);
    try std.testing.expectEqualStrings("System", system.?.namespace.name);
}
