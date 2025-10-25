const std = @import("std");

// Helper function must be top-level now.
fn addTestWithSummary(
    b: *std.Build,
    name: []const u8,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import,
) *std.Build.Step {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    const run = b.addRunArtifact(t);
    //run.addArgs(&.{"--summary-all"});
    const step = b.step(name, "Run tests with summary");
    step.dependOn(&run.step);
    return step;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const makeModule = struct {
        pub fn create(
            builder: *std.Build,
            path: []const u8,
            tgt: std.Build.ResolvedTarget,
            opt: std.builtin.OptimizeMode,
        ) *std.Build.Module {
            return builder.createModule(.{
                .root_source_file = builder.path(path),
                .target = tgt,
                .optimize = opt,
            });
        }
    }.create;

    // ──────────────── Modules ────────────────
    const cli_mod = makeModule(b, "src/cli/root.zig", target, optimize);
    const evaluator_mod = makeModule(b, "src/evaluator/root.zig", target, optimize);
    const lexer_mod = makeModule(b, "src/lexer/root.zig", target, optimize);
    const parser_mod = makeModule(b, "src/parser/root.zig", target, optimize);
    const stdlib_mod = makeModule(b, "src/stdlib/root.zig", target, optimize);
    const supervisor_mod = makeModule(b, "src/supervisor/root.zig", target, optimize);
    const types_mod = makeModule(b, "src/types/root.zig", target, optimize);

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "cli", .module = cli_mod },
        .{ .name = "evaluator", .module = evaluator_mod },
        .{ .name = "lexer", .module = lexer_mod },
        .{ .name = "parser", .module = parser_mod },
        .{ .name = "stdlib", .module = stdlib_mod },
        .{ .name = "supervisor", .module = supervisor_mod },
        .{ .name = "types", .module = types_mod },
    };

    // ──────────────── Executable ────────────────
    const exe = b.addExecutable(.{
        .name = "ripple",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    b.installArtifact(exe);

    // ──────────────── All tests ────────────────
    _ = addTestWithSummary(b, "test", "src/main.zig", target, optimize, imports);

    // ──────────────── Folder-specific / file-specific ────────────────
    const folder_opt = b.option([]const u8, "folder", "Run tests for a specific folder");
    const file_opt = b.option([]const u8, "file", "Run tests for a specific file (relative to src/)");

    if (folder_opt) |folder| {
        const path = std.fmt.allocPrint(b.allocator, "src/{s}/root.zig", .{folder}) catch unreachable;
        _ = addTestWithSummary(b, "set", path, target, optimize, imports);
    } else if (file_opt) |file| {
        const path = std.fmt.allocPrint(b.allocator, "src/{s}", .{file}) catch unreachable;
        _ = addTestWithSummary(b, "file", path, target, optimize, imports);
    }
}
