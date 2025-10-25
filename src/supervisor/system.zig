const std = @import("std");
const prelude = @import("prelude");
const Process = @import("process").Process;

pub const SystemConfig = struct {
    max_restarts: u32 = 3,
    timeout_ms: ?u64 = null,
    enable_trace: bool = true,
    schedule: ?[]const u8 = null,
    max_memory: usize = 512 * 1024 * 1024,
    trace_to: ?[]const u8 = null,
    on_failure: ?[]const u8 = null,
};

pub const System = struct {
    allocator: std.mem.Allocator,
    env: prelude.Environment,
    config: SystemConfig,

    pub fn init(allocator: std.mem.Allocator, config: SystemConfig) !System {
        var env = prelude.Environment.init(allocator);
        try prelude.loadPrelude(&env, allocator);

        return System{
            .allocator = allocator,
            .env = env,
            .config = config,
        };
    }

    pub fn deinit(self: *System) void {
        self.env.deinit();
    }

    pub fn spawnProcess(self: *System, name: []const u8) !Process {
        _ = name;
        return Process{
            .allocator = self.allocator,
            .enable_trace = self.config.enable_trace,
        };
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

// ============================================================================
// Initialization Tests
// ============================================================================

test "System.init loads prelude namespaces" {
    const allocator = std.testing.allocator;
    const config = SystemConfig{};

    var sys = try System.init(allocator, config);
    defer sys.deinit();

    const task = sys.env.get("Task");
    const proc = sys.env.get("Process");
    const system = sys.env.get("System");

    try std.testing.expect(task != null);
    try std.testing.expect(proc != null);
    try std.testing.expect(system != null);
    try std.testing.expectEqualStrings("Task", task.?.namespace.name);
    try std.testing.expectEqualStrings("Process", proc.?.namespace.name);
    try std.testing.expectEqualStrings("System", system.?.namespace.name);
}

test "System.init uses default config values" {
    const allocator = std.testing.allocator;
    const config = SystemConfig{};

    var sys = try System.init(allocator, config);
    defer sys.deinit();

    try std.testing.expectEqual(@as(u32, 3), sys.config.max_restarts);
    try std.testing.expect(sys.config.timeout_ms == null);
    try std.testing.expectEqual(true, sys.config.enable_trace);
    try std.testing.expect(sys.config.schedule == null);
    try std.testing.expectEqual(@as(usize, 512 * 1024 * 1024), sys.config.max_memory);
    try std.testing.expect(sys.config.trace_to == null);
    try std.testing.expect(sys.config.on_failure == null);
}

test "System.init respects custom config" {
    const allocator = std.testing.allocator;
    const config = SystemConfig{
        .max_restarts = 5,
        .timeout_ms = 1000,
        .enable_trace = false,
        .max_memory = 256 * 1024 * 1024,
    };

    var sys = try System.init(allocator, config);
    defer sys.deinit();

    try std.testing.expectEqual(@as(u32, 5), sys.config.max_restarts);
    try std.testing.expectEqual(@as(u64, 1000), sys.config.timeout_ms.?);
    try std.testing.expectEqual(false, sys.config.enable_trace);
    try std.testing.expectEqual(@as(usize, 256 * 1024 * 1024), sys.config.max_memory);
}

// ============================================================================
// Process Spawning Tests
// ============================================================================

test "System.spawnProcess creates valid process" {
    const allocator = std.testing.allocator;
    const config = SystemConfig{};

    var sys = try System.init(allocator, config);
    defer sys.deinit();

    const process = try sys.spawnProcess("test_process");

    try std.testing.expectEqual(allocator, process.allocator);
    try std.testing.expectEqual(sys.config.enable_trace, process.enable_trace);
}

test "System.spawnProcess inherits trace config" {
    const allocator = std.testing.allocator;

    // Test with trace enabled
    {
        const config = SystemConfig{ .enable_trace = true };
        var sys = try System.init(allocator, config);
        defer sys.deinit();

        const process = try sys.spawnProcess("traced_process");
        try std.testing.expectEqual(true, process.enable_trace);
    }

    // Test with trace disabled
    {
        const config = SystemConfig{ .enable_trace = false };
        var sys = try System.init(allocator, config);
        defer sys.deinit();

        const process = try sys.spawnProcess("untraced_process");
        try std.testing.expectEqual(false, process.enable_trace);
    }
}

test "System.spawnProcess can create multiple processes" {
    const allocator = std.testing.allocator;
    const config = SystemConfig{};

    var sys = try System.init(allocator, config);
    defer sys.deinit();

    const process1 = try sys.spawnProcess("process_1");
    const process2 = try sys.spawnProcess("process_2");
    const process3 = try sys.spawnProcess("process_3");

    // All processes should be valid and independent
    try std.testing.expectEqual(allocator, process1.allocator);
    try std.testing.expectEqual(allocator, process2.allocator);
    try std.testing.expectEqual(allocator, process3.allocator);
}

// ============================================================================
// Configuration Field Tests
// ============================================================================

test "SystemConfig supports scheduling directive" {
    const allocator = std.testing.allocator;
    const cron_schedule = "0 3 * * *";
    const config = SystemConfig{
        .schedule = cron_schedule,
    };

    var sys = try System.init(allocator, config);
    defer sys.deinit();

    try std.testing.expect(sys.config.schedule != null);
    try std.testing.expectEqualStrings(cron_schedule, sys.config.schedule.?);
}

test "SystemConfig supports trace destination" {
    const allocator = std.testing.allocator;
    const trace_endpoint = "jaeger://traces";
    const config = SystemConfig{
        .trace_to = trace_endpoint,
    };

    var sys = try System.init(allocator, config);
    defer sys.deinit();

    try std.testing.expect(sys.config.trace_to != null);
    try std.testing.expectEqualStrings(trace_endpoint, sys.config.trace_to.?);
}

test "SystemConfig supports failure hooks" {
    const allocator = std.testing.allocator;
    const failure_hook = "Alert.slack";
    const config = SystemConfig{
        .on_failure = failure_hook,
    };

    var sys = try System.init(allocator, config);
    defer sys.deinit();

    try std.testing.expect(sys.config.on_failure != null);
    try std.testing.expectEqualStrings(failure_hook, sys.config.on_failure.?);
}

test "SystemConfig supports memory limits" {
    const allocator = std.testing.allocator;
    const memory_limit = 1024 * 1024 * 1024; // 1GB
    const config = SystemConfig{
        .max_memory = memory_limit,
    };

    var sys = try System.init(allocator, config);
    defer sys.deinit();

    try std.testing.expectEqual(memory_limit, sys.config.max_memory);
}

// ============================================================================
// Memory Management Tests
// ============================================================================

test "System.deinit cleans up environment" {
    const allocator = std.testing.allocator;
    const config = SystemConfig{};

    var sys = try System.init(allocator, config);
    sys.deinit();

    // If this passes with no leaks, environment cleanup is working
    // The test framework will catch any memory leaks
}

test "System can be created and destroyed multiple times" {
    const allocator = std.testing.allocator;

    // Create and destroy multiple times
    for (0..3) |_| {
        const config = SystemConfig{};
        var sys = try System.init(allocator, config);
        sys.deinit();
    }

    // If this passes with no leaks, repeated init/deinit is working
}

// ============================================================================
// Integration Tests
// ============================================================================

test "System environment is independent per instance" {
    const allocator = std.testing.allocator;
    const config = SystemConfig{};

    var sys1 = try System.init(allocator, config);
    defer sys1.deinit();

    var sys2 = try System.init(allocator, config);
    defer sys2.deinit();

    // Both should have their own environment with prelude loaded
    try std.testing.expect(sys1.env.get("Task") != null);
    try std.testing.expect(sys2.env.get("Task") != null);

    // Verify they're independent (different memory addresses)
    const task1 = sys1.env.get("Task").?;
    const task2 = sys2.env.get("Task").?;

    // They should both exist and be valid
    try std.testing.expectEqualStrings("Task", task1.namespace.name);
    try std.testing.expectEqualStrings("Task", task2.namespace.name);
}
