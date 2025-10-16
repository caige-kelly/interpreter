const std = @import("std");
const Lambda = @import("ast.zig").LambdaExpr;

pub const Number = union(enum) {
    int: i64,
    float: f64,
};

// Result is separate—it's a runtime value, not a literal
pub const Result = struct {
    user: Value, // or could be union of possible types
    sys: Metadata,
};

pub const Value = union(enum) {
    number: Number,
    string: []const u8,
    boolean: bool,
    none: void,
    list: []Value,
    map: std.StringHashMap(Value),
    lambda: Lambda,  // if you want to store functions as values
    result: Result,      // Result itself can be a value
};

pub const Metadata = struct {
    duration_ms: u64,
    status: []const u8,
    retries: u32 = 0,
    // ... other fields as needed
};