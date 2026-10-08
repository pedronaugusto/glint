const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("glint", .{ .root_source_file = b.path("src/glint.zig"), .target = target, .optimize = optimize });
    const executable = b.addExecutable(.{ .name = "glint", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glint", .module = module }},
    }) });
    b.installArtifact(executable);
    if (b.pkg_hash.len != 0) return;
    const filter = b.option([]const u8, "test-filter", "Select tests by name");
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize }), .filters = if (filter) |f| &.{f} else &.{} });
    var needed: error{LazyDependencyNeeded}!void = {};
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })) |dep| tests.root_module.addImport("shakedown", dep.module("shakedown")) else |err| needed = err;
    const test_step = b.step("test", "Run selected contract tests and benchmark smoke");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const check = b.step("check", "Compile CLI and tests");
    check.dependOn(&tests.step);
    check.dependOn(&executable.step);
    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{ .tests = test_step, .portable_tests = true, .bench = .{
            .programs = &.{.{ .name = "glint-scan", .source = "bench/scan.zig" }},
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
        } });
        const dep = try b.dependencyLazy("preflight", .{});
        const plan = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--build-file" });
        plan.addFileArg(dep.path("build.zig"));
        plan.addDirectoryArg2(b.path("."), .{ .prefix = "-Drepo-root=" });
        plan.addArgs(&.{ "plan", "--" });
        plan.addPassthruArgs();
        b.step("plan", "Generate hosted CI through preflight").dependOn(&plan.step);
        preflight.addConsumerCheck(b, .{ .package = "glint", .program = b.path("ci/consumer.zig") });
    }
    return needed;
}

fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "glint", .module = b.createModule(.{ .root_source_file = b.path("src/glint.zig"), .target = target, .optimize = optimize }) }}) catch @panic("OOM");
}
