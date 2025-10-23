// result.zig
const std = @import("std");

pub const Metadata = struct {
    timestamp: i64,
    duration_ns: u64,
    expr_source: []const u8,
    extra: std.StringHashMap([]const u8), // ADD: extensible metadata
    allocator: std.mem.Allocator, // ADD: needed for HashMap

    pub fn init(expr_source: []const u8, allocator: std.mem.Allocator) Metadata {
        return .{
            .timestamp = std.time.milliTimestamp(),
            .duration_ns = 0,
            .expr_source = expr_source,
            .extra = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn withDuration(self: Metadata, duration_ns: u64) Metadata {
        var m = self;
        m.duration_ns = duration_ns;
        return m;
    }

    pub fn set(self: *Metadata, key: []const u8, value: []const u8) !void {
        try self.extra.put(key, value);
    }

    pub fn get(self: *const Metadata, key: []const u8) ?[]const u8 {
        return self.extra.get(key);
    }

    pub fn deinit(self: *Metadata) void {
        self.extra.deinit();
    }
};

// REMOVE: Don't need separate Error struct
// pub const Error = struct { ... };

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: struct {
            value: T,
            meta: Metadata,
        },
        err: struct {
            msg: []const u8, // FIX: Was Error type, should be []const u8
            meta: Metadata,
        },

        pub fn isOk(self: @This()) bool {
            return self == .ok;
        }

        pub fn isErr(self: @This()) bool {
            return self == .err;
        }

        pub fn unwrap(self: @This()) !T { // FIX: Return T, not Value. Use @This()
            return switch (self) {
                .ok => |ok_data| ok_data.value, // FIX: Destructure and get value
                .err => error.UnwrapError,
            };
        }
    };
}

// Helper constructors
pub fn ok(value: anytype, meta: Metadata) Result(@TypeOf(value)) {
    return .{
        .ok = .{
            .value = value,
            .meta = meta,
        },
    };
}

pub fn err(comptime T: type, msg: []const u8, meta: Metadata) Result(T) { // FIX: msg not error_msg
    return .{
        .err = .{
            .msg = msg, // FIX: Just the string, not wrapped in Error struct
            .meta = meta,
        },
    };
}
