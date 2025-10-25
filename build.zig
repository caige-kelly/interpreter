const std = @import("std");

fn addAndRunTest(
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
    const step = b.step(name, "Run tests for this module");
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

    // ──────────────── Define all modules ────────────────
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

    // ──────────────── Build main executable ────────────────
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

    // ──────────────── Run tests per module ────────────────
    const cli_step = addAndRunTest(b, "cli-tests", "src/cli/root.zig", target, optimize, imports);
    const evaluator_step = addAndRunTest(b, "evaluator-tests", "src/evaluator/root.zig", target, optimize, imports);
    const lexer_step = addAndRunTest(b, "lexer-tests", "src/lexer/root.zig", target, optimize, imports);
    const parser_step = addAndRunTest(b, "parser-tests", "src/parser/root.zig", target, optimize, imports);
    const stdlib_step = addAndRunTest(b, "stdlib-tests", "src/stdlib/root.zig", target, optimize, imports);
    const supervisor_step = addAndRunTest(b, "supervisor-tests", "src/supervisor/root.zig", target, optimize, imports);
    const types_step = addAndRunTest(b, "types-tests", "src/types/root.zig", target, optimize, imports);

    // ──────────────── Aggregate "test" step ────────────────
    const all_tests = b.step("test", "Run all module tests");

    all_tests.dependOn(cli_step);
    all_tests.dependOn(evaluator_step);
    all_tests.dependOn(lexer_step);
    all_tests.dependOn(parser_step);
    all_tests.dependOn(stdlib_step);
    all_tests.dependOn(supervisor_step);
    all_tests.dependOn(types_step);

    // ──────────────── Folder / File specific ────────────────
    const folder_opt = b.option([]const u8, "folder", "Run tests for a specific folder");
    const file_opt = b.option([]const u8, "file", "Run tests for a specific file (relative to src/)");

    if (folder_opt) |folder| {
        const path = std.fmt.allocPrint(b.allocator, "src/{s}/root.zig", .{folder}) catch unreachable;
        _ = addAndRunTest(b, "set", path, target, optimize, imports);
    } else if (file_opt) |file| {
        const dirname = std.fs.path.dirname(file) orelse "";
        const is_zig_file = std.mem.endsWith(u8, file, ".zig");

        const path = if (is_zig_file and dirname.len > 0)
            std.fmt.allocPrint(b.allocator, "src/{s}/root.zig", .{dirname}) catch unreachable
        else
            std.fmt.allocPrint(b.allocator, "src/{s}", .{file}) catch unreachable;

        _ = addAndRunTest(b, "file", path, target, optimize, imports);
    }
}
