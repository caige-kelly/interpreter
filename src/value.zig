// value.zig
const std = @import("std");

pub const ResultTag = enum { ok, err };

pub const ResultValue = struct {
    tag: ResultTag,
    system: ?*Value, // machine-facing payload
    user: ?*Value, // human-readable payload
};

pub const Value = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    list: []Value,
    map: []KeyValue,
    result: ResultValue,
    none: void,

    // Convenience helpers
    pub fn isNone(self: Value) bool {
        return self == .none;
    }

    pub fn isResult(self: Value) bool {
        return self == .result;
    }

    pub fn unwrapSystem(self: Value) ?*Value {
        return if (self == .result) self.result.system else null;
    }

    pub fn unwrapUser(self: Value) ?*Value {
        return if (self == .result) self.result.user else null;
    }

    pub fn makeOk(system: *Value, user: *Value) Value {
        return Value{ .result = .{ .tag = .ok, .system = system, .user = user } };
    }

    pub fn makeErr(system: *Value, user: *Value) Value {
        return Value{ .result = .{ .tag = .err, .system = system, .user = user } };
    }
};

pub const KeyValue = struct {
    key: []const u8,
    value: *Value,
};
