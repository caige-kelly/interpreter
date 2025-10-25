const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value").Value;

/// Environment manages variable bindings with deep-copy semantics
/// Each value stored is cloned to ensure the environment owns its data
pub const Environment = struct {
    bindings: std.StringHashMap(Value),
    allocator: Allocator,

    /// Create a new empty environment
    pub fn init(allocator: Allocator) !Environment {
        return .{
            .bindings = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
        };
    }

    /// Free all values and the environment itself
    pub fn deinit(self: *Environment) void {
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            // Free the key (owned by hashmap)
            self.allocator.free(entry.key_ptr.*);
            // Free the value
            entry.value_ptr.deinit();
        }
        self.bindings.deinit();
    }

    /// Set a variable, cloning the value so environment owns it
    /// The incoming value is NOT consumed - caller still owns it
    pub fn set(self: *Environment, name: []const u8, value: Value) !void {
        // Clone the value so environment owns it
        const owned_value = try value.clone(self.allocator);

        // Check if variable already exists
        if (self.bindings.getPtr(name)) |existing| {
            // Free old value
            existing.deinit();
            // Update with new value
            existing.* = owned_value;
        } else {
            // Create owned copy of name
            const owned_name = try self.allocator.dupe(u8, name);
            // Store new binding
            try self.bindings.put(owned_name, owned_value);
        }
    }

    /// Get a variable by name, returns a borrowed reference
    /// Caller does NOT own the returned value
    pub fn get(self: *const Environment, name: []const u8) ?Value {
        return self.bindings.get(name);
    }

    /// Check if a variable exists
    pub fn has(self: *const Environment, name: []const u8) bool {
        return self.bindings.contains(name);
    }

    /// Remove a variable, freeing its value
    pub fn remove(self: *Environment, name: []const u8) void {
        if (self.bindings.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit();
        }
    }

    /// Get number of bindings
    pub fn count(self: *const Environment) usize {
        return self.bindings.count();
    }

    /// Clear all bindings
    pub fn clear(self: *Environment) void {
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.bindings.clearRetainingCapacity();
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Environment: init and deinit" {
    var env = try Environment.init(testing.allocator);
    defer env.deinit();

    try testing.expectEqual(0, env.count());
}

test "Environment: set and get number" {
    var env = try Environment.init(testing.allocator);
    defer env.deinit();

    const value = Value.initStack(.{ .number = 42.0 });
    try env.set("x", value);

    const retrieved = env.get("x");
    try testing.expect(retrieved != null);
    try testing.expectEqual(42.0, retrieved.?.data.number);
}

test "Environment: set and get string" {
    var env = try Environment.init(testing.allocator);
    defer env.deinit();

    const str = try testing.allocator.dupe(u8, "hello");
    const value = Value.init(testing.allocator, .{ .string = str });
    defer value.deinit(); // Caller still owns original

    try env.set("msg", value);

    const retrieved = env.get("msg");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("hello", retrieved.?.data.string);
}

test "Environment: rebinding updates value" {
    var env = try Environment.init(testing.allocator);
    defer env.deinit();

    const v1 = Value.initStack(.{ .number = 10.0 });
    try env.set("x", v1);

    const v2 = Value.initStack(.{ .number = 20.0 });
    try env.set("x", v2);

    const retrieved = env.get("x");
    try testing.expectEqual(20.0, retrieved.?.data.number);
}

test "Environment: has checks existence" {
    var env = try Environment.init(testing.allocator);
    defer env.deinit();

    try testing.expect(!env.has("x"));

    const value = Value.initStack(.{ .number = 42.0 });
    try env.set("x", value);

    try testing.expect(env.has("x"));
}

test "Environment: remove deletes binding" {
    var env = try Environment.init(testing.allocator);
    defer env.deinit();

    const value = Value.initStack(.{ .number = 42.0 });
    try env.set("x", value);

    try testing.expect(env.has("x"));

    env.remove("x");

    try testing.expect(!env.has("x"));
    try testing.expectEqual(0, env.count());
}

test "Environment: clear removes all bindings" {
    var env = try Environment.init(testing.allocator);
    defer env.deinit();

    const v1 = Value.initStack(.{ .number = 1.0 });
    const v2 = Value.initStack(.{ .number = 2.0 });
    const v3 = Value.initStack(.{ .number = 3.0 });

    try env.set("a", v1);
    try env.set("b", v2);
    try env.set("c", v3);

    try testing.expectEqual(3, env.count());

    env.clear();

    try testing.expectEqual(0, env.count());
}

test "Environment: multiple variables" {
    var env = try Environment.init(testing.allocator);
    defer env.deinit();

    const v1 = Value.initStack(.{ .number = 10.0 });
    const v2 = Value.initStack(.{ .boolean = true });
    const v3 = Value.initStack(.{ .none = {} });

    try env.set("x", v1);
    try env.set("flag", v2);
    try env.set("empty", v3);

    try testing.expectEqual(3, env.count());
    try testing.expectEqual(10.0, env.get("x").?.data.number);
    try testing.expectEqual(true, env.get("flag").?.data.boolean);
    try testing.expect(env.get("empty").?.data == .none);
}

test "Environment: value cloning ensures ownership" {
    var env = try Environment.init(testing.allocator);
    defer env.deinit();

    const str = try testing.allocator.dupe(u8, "test");
    const original = Value.init(testing.allocator, .{ .string = str });
    defer original.deinit(); // Original is freed here

    try env.set("msg", original);

    // Environment should have its own copy
    const retrieved = env.get("msg");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("test", retrieved.?.data.string);

    // Different pointers (environment has its own copy)
    try testing.expect(original.data.string.ptr != retrieved.?.data.string.ptr);
}

test "Memory: no leaks with complex values" {
    var env = try Environment.init(testing.allocator);
    defer env.deinit();

    // Store multiple string values
    for (0..10) |i| {
        const str = try std.fmt.allocPrint(testing.allocator, "value_{}", .{i});
        const value = Value.init(testing.allocator, .{ .string = str });
        defer value.deinit();

        const name = try std.fmt.allocPrint(testing.allocator, "var_{}", .{i});
        defer testing.allocator.free(name);

        try env.set(name, value);
    }

    try testing.expectEqual(10, env.count());

    // deinit should clean everything
}
