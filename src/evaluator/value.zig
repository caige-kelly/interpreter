const std = @import("std");
const Allocator = std.mem.Allocator;

/// ValueData represents the actual data stored in a Value
pub const ValueData = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    none: void,
    result: *Result,

    pub fn format(
        self: ValueData,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .number => |n| try writer.print("{d}", .{n}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .boolean => |b| try writer.print("{}", .{b}),
            .none => try writer.writeAll("none"),
            .result => |r| try writer.print("Result({})", .{r.isOk()}),
        }
    }
};

/// Value is a self-managing type that knows how to clean itself up
///
/// Values can be:
/// - Stack-allocated (allocator = null) - won't be freed
/// - Heap-allocated (allocator != null) - will be freed on deinit
pub const Value = struct {
    data: ValueData,
    allocator: ?Allocator,

    /// Create a stack value (no allocator, won't be freed)
    /// Use this for literal values and temporary stack allocations
    pub fn initStack(data: ValueData) Value {
        return .{
            .data = data,
            .allocator = null,
        };
    }

    /// Create a heap value (has allocator, will be freed)
    /// Use this for values that need to survive beyond current scope
    pub fn init(allocator: Allocator, data: ValueData) Value {
        return .{
            .data = data,
            .allocator = allocator,
        };
    }

    /// Free all owned resources
    /// Safe to call on stack values (allocator = null)
    pub fn deinit(self: Value) void {
        const alloc = self.allocator orelse return;

        switch (self.data) {
            .string => |s| alloc.free(s),
            .result => |r| {
                r.deinit();
                alloc.destroy(r);
            },
            .number, .boolean, .none => {},
        }
    }

    /// Deep copy this value using a new allocator
    /// This is essential for storing values in environments
    pub fn clone(self: Value, allocator: Allocator) Allocator.Error!Value {
        const data = switch (self.data) {
            .number => |n| ValueData{ .number = n },
            .boolean => |b| ValueData{ .boolean = b },
            .none => ValueData{ .none = {} },
            .string => |s| ValueData{
                .string = try allocator.dupe(u8, s),
            },
            .result => |r| ValueData{
                .result = try r.clone(allocator),
            },
        };

        return Value.init(allocator, data);
    }

    /// Check if two values are equal
    pub fn eql(self: Value, other: Value) bool {
        if (@as(std.meta.Tag(ValueData), self.data) != @as(std.meta.Tag(ValueData), other.data)) {
            return false;
        }

        return switch (self.data) {
            .number => |n| n == other.data.number,
            .boolean => |b| b == other.data.boolean,
            .none => true,
            .string => |s| std.mem.eql(u8, s, other.data.string),
            .result => |r| r.eql(other.data.result),
        };
    }

    pub fn format(
        self: Value,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try self.data.format(fmt, options, writer);
    }
};

/// ErrorInfo holds error information
pub const ErrorInfo = struct {
    message: []const u8,
};

/// Result wraps a Value or Error with metadata
/// This is the foundation of Ripple's error handling
pub const Result = struct {
    payload: union(enum) {
        ok: Value,
        err: ErrorInfo,
    },
    allocator: Allocator,

    /// Create a successful Result
    pub fn initOk(allocator: Allocator, value: Value) Allocator.Error!*Result {
        const r = try allocator.create(Result);
        r.* = .{
            .payload = .{ .ok = value },
            .allocator = allocator,
        };
        return r;
    }

    /// Create an error Result
    pub fn initErr(allocator: Allocator, msg: []const u8) Allocator.Error!*Result {
        const r = try allocator.create(Result);
        const msg_copy = try allocator.dupe(u8, msg);
        r.* = .{
            .payload = .{
                .err = .{ .message = msg_copy },
            },
            .allocator = allocator,
        };
        return r;
    }

    /// Free all owned resources
    pub fn deinit(self: *Result) void {
        switch (self.payload) {
            .ok => |v| v.deinit(),
            .err => |e| self.allocator.free(e.message),
        }
    }

    /// Deep copy this Result
    pub fn clone(self: *Result, allocator: Allocator) Allocator.Error!*Result {
        return switch (self.payload) {
            .ok => |v| try Result.initOk(allocator, try v.clone(allocator)),
            .err => |e| try Result.initErr(allocator, e.message),
        };
    }

    /// Check if this is a successful result
    pub fn isOk(self: *const Result) bool {
        return self.payload == .ok;
    }

    /// Check if this is an error result
    pub fn isErr(self: *const Result) bool {
        return self.payload == .err;
    }

    /// Get the success value (panics if error)
    pub fn unwrap(self: *const Result) Value {
        return switch (self.payload) {
            .ok => |v| v,
            .err => |e| @panic(e.message),
        };
    }

    /// Get the error message (panics if ok)
    pub fn unwrapErr(self: *const Result) []const u8 {
        return switch (self.payload) {
            .ok => @panic("called unwrapErr on ok Result"),
            .err => |e| e.message,
        };
    }

    /// Check equality
    pub fn eql(self: *const Result, other: *const Result) bool {
        if (@as(std.meta.Tag(@TypeOf(self.payload)), self.payload) !=
            @as(std.meta.Tag(@TypeOf(other.payload)), other.payload))
        {
            return false;
        }

        return switch (self.payload) {
            .ok => |v| v.eql(other.payload.ok),
            .err => |e| std.mem.eql(u8, e.message, other.payload.err.message),
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Value: stack allocation (number)" {
    const v = Value.initStack(.{ .number = 42.0 });
    try testing.expectEqual(42.0, v.data.number);
    try testing.expect(v.allocator == null);
    v.deinit(); // Safe to call, does nothing
}

test "Value: stack allocation (boolean)" {
    const v = Value.initStack(.{ .boolean = true });
    try testing.expect(v.data.boolean);
    v.deinit(); // Safe to call
}

test "Value: stack allocation (none)" {
    const v = Value.initStack(.{ .none = {} });
    try testing.expect(v.data == .none);
    v.deinit(); // Safe to call
}

test "Value: heap string allocation" {
    const allocator = testing.allocator;

    const str = try allocator.dupe(u8, "hello");
    const v = Value.init(allocator, .{ .string = str });
    defer v.deinit();

    try testing.expectEqualStrings("hello", v.data.string);
    try testing.expect(v.allocator != null);
}

test "Value: clone number" {
    const allocator = testing.allocator;

    const original = Value.initStack(.{ .number = 3.14 });
    const cloned = try original.clone(allocator);
    defer cloned.deinit();

    try testing.expectEqual(original.data.number, cloned.data.number);
    try testing.expect(cloned.allocator != null); // Cloned is heap-allocated
}

test "Value: clone string" {
    const allocator = testing.allocator;

    const str = try allocator.dupe(u8, "test");
    const original = Value.init(allocator, .{ .string = str });
    defer original.deinit();

    const cloned = try original.clone(allocator);
    defer cloned.deinit();

    try testing.expectEqualStrings(original.data.string, cloned.data.string);
    // Different pointers (deep copy)
    try testing.expect(original.data.string.ptr != cloned.data.string.ptr);
}

test "Value: equality" {
    const v1 = Value.initStack(.{ .number = 42.0 });
    const v2 = Value.initStack(.{ .number = 42.0 });
    const v3 = Value.initStack(.{ .number = 43.0 });

    try testing.expect(v1.eql(v2));
    try testing.expect(!v1.eql(v3));
}

test "Result: ok creation" {
    const allocator = testing.allocator;

    const value = Value.initStack(.{ .number = 42.0 });
    const result = try Result.initOk(allocator, value);
    defer allocator.destroy(result);
    defer result.deinit();

    try testing.expect(result.isOk());
    try testing.expect(!result.isErr());
    try testing.expectEqual(42.0, result.unwrap().data.number);
}

test "Result: err creation" {
    const allocator = testing.allocator;

    const result = try Result.initErr(allocator, "something failed");
    defer allocator.destroy(result);
    defer result.deinit();

    try testing.expect(result.isErr());
    try testing.expect(!result.isOk());
    try testing.expectEqualStrings("something failed", result.unwrapErr());
}

test "Result: clone ok" {
    const allocator = testing.allocator;

    const value = Value.initStack(.{ .number = 100.0 });
    const original = try Result.initOk(allocator, value);
    defer allocator.destroy(original);
    defer original.deinit();

    const cloned = try original.clone(allocator);
    defer allocator.destroy(cloned);
    defer cloned.deinit();

    try testing.expect(cloned.isOk());
    try testing.expectEqual(100.0, cloned.unwrap().data.number);
}

test "Result: clone err" {
    const allocator = testing.allocator;

    const original = try Result.initErr(allocator, "error message");
    defer allocator.destroy(original);
    defer original.deinit();

    const cloned = try original.clone(allocator);
    defer allocator.destroy(cloned);
    defer cloned.deinit();

    try testing.expect(cloned.isErr());
    try testing.expectEqualStrings("error message", cloned.unwrapErr());
}

test "Result: nested in Value" {
    const allocator = testing.allocator;

    const inner_value = Value.initStack(.{ .number = 42.0 });
    const result = try Result.initOk(allocator, inner_value);

    const value = Value.init(allocator, .{ .result = result });
    defer value.deinit(); // Should recursively clean up result

    try testing.expect(value.data.result.isOk());
}

test "Memory: no leaks with complex Value" {
    const allocator = testing.allocator;

    // Create a complex nested structure
    const str = try allocator.dupe(u8, "test string");
    const inner = Value.init(allocator, .{ .string = str });

    const result = try Result.initOk(allocator, inner);
    const outer = Value.init(allocator, .{ .result = result });

    // Single deinit should clean everything
    outer.deinit();
}
