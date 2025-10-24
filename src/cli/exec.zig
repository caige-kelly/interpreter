const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("../system.zig");
const Supervisor = @import("../supervisor.zig").Supervisor;
const SupervisionResult = @import("../supervisor.zig").SupervisionResult;
const Value = @import("../evaluator.zig").Value;

pub const ExecOptions = struct {
    trace: bool = true,
    timeout_ms: ?u64 = null,
    retries: u32 = 3,
    max_memory: usize = 512 * 1024 * 1024,
    quiet: bool = false,
};

pub fn run(allocator: Allocator, args: *std.process.ArgIterator) !void {
    var options = ExecOptions{};
    var script_path: ?[]const u8 = null;

    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            options.trace = true;
        } else if (std.mem.eql(u8, arg, "--no-trace")) {
            options.trace = false;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            options.quiet = true;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            const timeout_str = args.next() orelse {
                std.debug.print("Error: --timeout requires a value\n", .{});
                std.process.exit(1);
            };
            options.timeout_ms = try std.fmt.parseInt(u64, timeout_str, 10);
        } else if (std.mem.eql(u8, arg, "--retries")) {
            const retries_str = args.next() orelse {
                std.debug.print("Error: --retries requires a value\n", .{});
                std.process.exit(1);
            };
            options.retries = try std.fmt.parseInt(u32, retries_str, 10);
        } else if (std.mem.eql(u8, arg, "--max-memory")) {
            const memory_str = args.next() orelse {
                std.debug.print("Error: --max-memory requires a value\n", .{});
                std.process.exit(1);
            };
            options.max_memory = try parseMemorySize(memory_str);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Error: Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        } else {
            if (script_path != null) {
                std.debug.print("Error: Multiple script paths provided\n", .{});
                std.process.exit(1);
            }
            script_path = arg;
        }
    }

    // Validate script path
    const path = script_path orelse {
        std.debug.print("Error: No script path provided\n\n", .{});
        printHelp();
        std.process.exit(1);
    };

    // Execute the script
    try executeScript(allocator, path, options);
}

fn executeScript(allocator: Allocator, path: []const u8, options: ExecOptions) !void {
    // Read the script file
    const source = std.fs.cwd().readFileAlloc(
        path,
        allocator,
        std.Io.Limit.limited(10 * 1024 * 1024), // Max 10MB file
    ) catch |err| {
        std.debug.print("Error reading file '{s}': {any}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    // Create system config
    const sys_config = sys.SystemConfig{
        .max_restarts = options.retries,
        .timeout_ms = options.timeout_ms,
        .enable_trace = options.trace,
        .max_memory = options.max_memory,
    };

    // Initialize system
    var system = try sys.System.init(allocator, sys_config);
    defer system.deinit();

    // Create supervisor
    var supervisor = Supervisor{ .system = system };

    // Run the script
    if (!options.quiet) {
        std.debug.print("Executing {s}...\n", .{path});
    }

    const start_time = try std.time.Instant.now();

    var result = supervisor.run(source) catch |err| {
        std.debug.print("Error executing script: {any}\n", .{err});
        std.process.exit(1);
    };
    defer result.deinit();

    const end_time = try std.time.Instant.now();
    const duration_ms = end_time.since(start_time) / std.time.ns_per_ms;

    // Buffered stdout writer
    var out_buf: [4096]u8 = undefined;
    var file_stdout_writer = std.fs.File.stdout().writer(&out_buf);
    const stdout: *std.Io.Writer = &file_stdout_writer.interface;

    // Print results
    try printSupervisionResult(stdout, result, duration_ms, options.quiet);
    try stdout.flush();

    // Exit with appropriate code
    const exit_code: u8 = switch (result.status) {
        .success => 0,
        else => 1,
    };
    std.process.exit(exit_code);
}

fn printValue(writer: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .number => |n| try writer.print("{d}", .{n}),
        .string => |s| try writer.print("\"{s}\"", .{s}),
        .boolean => |b| try writer.print("{}", .{b}),
        .none => try writer.print("none", .{}),
        .result => |r| {
            if (r.isOk()) {
                if (r.value) |val| {
                    try writer.print("Ok(", .{});
                    try printValue(writer, val); // Remove the .* here
                    try writer.print(")", .{});
                } else {
                    try writer.print("Ok(none)", .{});
                }
            } else {
                if (r.err_msg) |msg| {
                    try writer.print("Err(\"{s}\")", .{msg});
                } else {
                    try writer.print("Err(unknown)", .{});
                }
            }
        },
    }
}

fn printSupervisionResult(writer: *std.Io.Writer, result: SupervisionResult, duration_ms: u64, quiet: bool) !void {
    if (quiet) {
        // Only print the value
        if (result.final_value) |value| {
            try printValue(writer, value);
            try writer.print("\n", .{});
        }
        return;
    }

    // Print detailed results
    switch (result.status) {
        .success => {
            try writer.print("Success!\n", .{});
            if (result.final_value) |value| {
                try writer.print("Result: ", .{});
                try printValue(writer, value);
                try writer.print("\n", .{});
            }
            try writer.print("Duration: {}ms\n", .{duration_ms});
            try writer.print("Attempts: {}\n", .{result.attempts});
        },
        .parse_error => {
            try writer.print("Parse Error!\n", .{});
            if (result.last_error) |err| {
                try writer.print("Error: {s}\n", .{err});
            }
        },
        .eval_error => {
            try writer.print("Evaluation Error!\n", .{});
            if (result.last_error) |err| {
                try writer.print("Error: {s}\n", .{err});
            }
        },
        .failed_max_restarts => {
            try writer.print("Failed after {} attempts\n", .{result.attempts});
            if (result.last_error) |err| {
                try writer.print("Last error: {s}\n", .{err});
            }
        },
        .timeout => {
            try writer.print("Timeout!\n", .{});
        },
    }
}

fn parseMemorySize(str: []const u8) !usize {
    // Support formats like: "512MB", "1GB", "256M", "1024"
    var value: usize = 0;
    var multiplier: usize = 1;
    var i: usize = 0;

    // Parse the numeric part
    while (i < str.len and std.ascii.isDigit(str[i])) : (i += 1) {
        value = value * 10 + (str[i] - '0');
    }

    // Parse the unit suffix
    if (i < str.len) {
        const suffix = str[i..];
        if (std.mem.eql(u8, suffix, "KB") or std.mem.eql(u8, suffix, "K")) {
            multiplier = 1024;
        } else if (std.mem.eql(u8, suffix, "MB") or std.mem.eql(u8, suffix, "M")) {
            multiplier = 1024 * 1024;
        } else if (std.mem.eql(u8, suffix, "GB") or std.mem.eql(u8, suffix, "G")) {
            multiplier = 1024 * 1024 * 1024;
        } else {
            return error.InvalidMemorySize;
        }
    }

    return value * multiplier;
}

fn printHelp() void {
    const help =
        \\Usage: rvm exec <script> [options]
        \\
        \\Execute a Ripple script with supervision and retry logic.
        \\
        \\Options:
        \\  --trace              Enable execution trace (default: true)
        \\  --no-trace           Disable execution trace
        \\  --timeout <ms>       Execution timeout in milliseconds
        \\  --retries <n>        Max retry attempts on failure (default: 3)
        \\  --max-memory <size>  Memory limit (e.g., 512MB, 1GB) (default: 512MB)
        \\  -q, --quiet          Only output the result value (no diagnostics)
        \\  -h, --help           Show this help message
        \\
        \\Examples:
        \\  rvm exec backup.rip
        \\  rvm exec backup.rip --quiet
        \\  rvm exec backup.rip --trace --timeout 30000
        \\  rvm exec backup.rip --retries 5 --max-memory 1GB
        \\
    ;
    std.debug.print("{s}", .{help});
}
