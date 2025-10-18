const std = @import("std");

// === Tests === //
const testing = std.testing;

test "supervisor: successful evaluation on first attempt" {
    const allocator = testing.allocator;
    const source = "x := 42";

    const config = SupervisorConfig{
        .max_restarts = 3,
        .enable_trace = true,
    };

    var supervisor = try Supervisor.init(allocator, config);
    defer supervisor.deinit();

    const result = try supervisor.run(source);
    defer result.deinit(allocator); // Need to free trace, etc.

    // Should succeed on first try
    try testing.expectEqual(SupervisionResult.Status.success, result.status);
    try testing.expectEqual(@as(u32, 1), result.attempts);

    // Should have a value
    try testing.expect(result.final_value != null);
    try testing.expectEqual(Value{ .number = 42.0 }, result.final_value.?);

    // Should have no error
    try testing.expect(result.last_error == null);

    // Should have trace (if enabled)
    try testing.expect(result.trace.len > 0);
}
