const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const aegis_dependency = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    const aegis = aegis_dependency.module("aegis");
    const token_module = b.addModule("glint_token", .{ .root_source_file = b.path("src/Token.zig"), .target = target, .optimize = optimize });
    const module = b.addModule("glint", .{ .root_source_file = b.path("src/glint.zig"), .target = target, .optimize = optimize });
    module.addImport("aegis", aegis);
    module.addImport("glint_token", token_module);
    const cli_module = b.addModule("glint_cli", .{ .root_source_file = b.path("src/cli.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "glint", .module = module }, .{ .name = "aegis", .module = aegis } } });

    const executable = b.addExecutable(.{ .name = "glint", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glint", .module = module }},
    }) });
    executable.root_module.addImport("aegis", aegis);
    b.installArtifact(executable);
    if (b.pkg_hash.len != 0) return;
    const portable = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const portable_tokens = b.createModule(.{ .root_source_file = b.path("src/Token.zig"), .target = portable, .optimize = .small });
    const portable_contract = b.addObject(.{ .name = "token-portable", .root_module = b.createModule(.{
        .root_source_file = b.path("ci/token_portable.zig"),
        .target = portable,
        .optimize = .small,
        .imports = &.{.{ .name = "glint_token", .module = portable_tokens }},
    }) });
    b.step("check-token-portable", "Compile the std-only token API at a different pointer width").dependOn(&portable_contract.step);
    const filter = b.option([]const u8, "test-filter", "Select tests by name");
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize }), .filters = if (filter) |f| &.{f} else &.{} });
    tests.root_module.addImport("aegis", aegis);
    tests.root_module.addImport("glint", module);
    tests.root_module.addImport("aegis_sources", aegisSources(b, module, aegis_dependency, target));
    var needed: error{LazyDependencyNeeded}!void = {};
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })) |dep| {
        tests.root_module.addImport("shakedown", dep.module("shakedown"));
    } else |err| needed = err;
    const test_step = b.step("test", "Run selected contract tests and benchmark smoke");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const library_tests = b.addTest(.{ .root_module = module, .filters = if (filter) |f| &.{f} else &.{} });
    test_step.dependOn(&b.addRunArtifact(library_tests).step);
    const project_linter = b.addExecutable(.{ .name = "glint-project-example", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/project.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "glint", .module = module }, .{ .name = "glint_cli", .module = cli_module } },
    }) });
    const project_check = b.step("check-project", "Compile a standalone linter with project-owned rules");
    project_check.dependOn(&project_linter.step);
    const project_smoke = addLint(b, project_linter, .{ .sources = &.{b.path("examples/report.zig")}, .directories = &.{b.path("examples")}, .args = &.{ "--only", "LOCAL_EXPORT" } });
    const source_policy = addLint(b, executable, .{
        .sources = &.{
            b.path("src/AegisContract.zig"),
            b.path("src/AegisPack.zig"),
            b.path("src/AegisPack_test.zig"),
            b.path("src/BuildGate.zig"),
            b.path("src/Builtins.zig"),
            b.path("src/Completion.zig"),
            b.path("src/DeadDeclarations.zig"),
            b.path("src/Facts.zig"),
            b.path("src/File.zig"),
            b.path("src/Library.zig"),
            b.path("src/Library_test.zig"),
            b.path("src/Model.zig"),
            b.path("src/Project.zig"),
            b.path("src/Projection.zig"),
            b.path("src/Projection_test.zig"),
            b.path("src/Token.zig"),
            b.path("src/Token/liveness.zig"),
            b.path("src/Token/store.zig"),
            b.path("src/Token/data.zig"),
            b.path("src/Token_test.zig"),
            b.path("src/Report.zig"),
            b.path("src/Result.zig"),
            b.path("src/Rule.zig"),
            b.path("src/RuleContext.zig"),
            b.path("src/RuleContext_test.zig"),
            b.path("src/Runner.zig"),
            b.path("src/Runner_test.zig"),
            b.path("src/Suppression.zig"),
            b.path("src/Usage.zig"),
            b.path("src/build_gate_test.zig"),
            b.path("src/cli.zig"),
            b.path("src/cli_test.zig"),
            b.path("src/contract_test.zig"),
            b.path("src/glint.zig"),
            b.path("src/main.zig"),
            b.path("src/names.zig"),
            b.path("src/tests.zig"),
        },
        .directories = &.{b.path("src")},
        .args = &.{ "--only", "P001", "--only", "P002", "--only", "P003", "--gate", "P001", "--gate", "P002", "--gate", "P003" },
    });
    b.step("check-source-policy", "Verify complete all-cast, safety-off and length policy on explicit own inputs").dependOn(&source_policy.step);
    const helper_check = b.step("check-helper", "Verify the public helper's exact source and directory inputs");
    helper_check.dependOn(&project_smoke.step);
    const portable_smoke = b.addRunArtifact(project_linter);
    portable_smoke.addArgs(&.{ "--only", "LOCAL_EXPORT", "examples/input.zig" });
    portable_smoke.addFileInput(b.path("examples/input.zig"));
    test_step.dependOn(&portable_smoke.step);
    const check = b.step("check", "Compile CLI and tests");
    check.dependOn(&tests.step);
    check.dependOn(&executable.step);
    check.dependOn(&project_linter.step);
    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{ .tests = test_step, .portable_tests = true, .bench = .{
            .programs = &.{ .{ .name = "glint-scan", .source = "bench/scan.zig" }, .{ .name = "glint-aegis", .source = "bench/aegis.zig" } },
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
        } });
        preflight.addConsumerCheck(b, .{ .package = "glint", .program = b.path("ci/consumer.zig"), .modules = &.{ "glint", "glint_token" }, .packages = &.{aegis_dependency} });
    }
    return needed;
}

fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const module = b.createModule(.{ .root_source_file = b.path("src/glint.zig"), .target = target, .optimize = optimize });
    module.addImport("glint_token", b.createModule(.{ .root_source_file = b.path("src/Token.zig"), .target = target, .optimize = optimize }));
    const aegis_dependency = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    module.addImport("aegis", aegis_dependency.module("aegis"));
    return b.allocator.dupe(std.Build.Module.Import, &.{ .{ .name = "glint", .module = module }, .{ .name = "aegis_sources", .module = aegisSources(b, module, aegis_dependency, target) } }) catch @panic("OOM");
}

/// The pinned aegis files that publish the pack's members, embedded as sources to analyze.
fn aegisSources(b: *std.Build, glint: *std.Build.Module, aegis_dependency: *std.Build.Dependency, target: std.Build.ResolvedTarget) *std.Build.Module {
    const sources = b.createModule(.{ .root_source_file = b.path("ci/aegis_sources.zig"), .target = target });
    sources.addImport("glint", glint);
    const files = [_][2][]const u8{
        .{ "aegis-root", "src/root.zig" },
        .{ "aegis-secret", "src/secret.zig" },
        .{ "aegis-secret-inline", "src/secret/inline.zig" },
        .{ "aegis-secret-bytes", "src/secret/SecretBytes.zig" },
        .{ "aegis-sync", "src/sync.zig" },
        .{ "aegis-guarded", "src/Guarded.zig" },
        .{ "aegis-int", "src/int.zig" },
        .{ "aegis-id", "src/id.zig" },
        .{ "aegis-units", "src/units.zig" },
        .{ "aegis-scalar", "src/scalar.zig" },
    };
    for (files) |file| sources.addAnonymousImport(file[0], .{ .root_source_file = aegis_dependency.path(file[1]), .target = target });
    return sources;
}

/// Builds a project's linter with statically compiled Zig rules and the standalone CLI.
pub fn addLinter(b: *std.Build, dependency: *std.Build.Dependency, options: LinterOptions) *std.Build.Step.Compile {
    return b.addExecutable(.{ .name = options.name, .root_module = b.createModule(.{
        .root_source_file = options.source,
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{ .{ .name = "glint", .module = dependency.module("glint") }, .{ .name = "glint_cli", .module = dependency.module("glint_cli") } },
    }) });
}
pub const LinterOptions = struct { name: []const u8 = "project-lint", source: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize = .debug };
/// Declares exact source/config and caller-selected directory-content inputs.
/// The directory inputs only invalidate the build; they never select files for glint.
pub fn addLint(b: *std.Build, executable: *std.Build.Step.Compile, options: LintOptions) *std.Build.Step.Run {
    const module = executable.root_module.import_table.get("glint") orelse @panic("linter must import glint");
    const gate = b.addExecutable(.{ .name = "glint-build-gate", .root_module = b.createModule(.{
        .root_source_file = module.root_source_file.?.dirname().path(b, "BuildGate.zig"),
        .target = b.graph.host,
        .optimize = .fast,
        .imports = &.{.{ .name = "glint", .module = module }},
    }) });
    const run = b.addRunArtifact(gate);
    run.addArtifactArg(executable);
    run.addDirectoryArg(b.tmpPath());
    if (options.config) |config| {
        run.addArg("--config");
        run.addFileArg(config);
    }
    for (options.sources) |source| run.addFileArg(source);
    for (options.directories) |directory| {
        run.addArg("--input-directory");
        run.addDirectoryArg(directory);
    }
    for (options.inputs) |input| run.addFileInput(input);
    run.addArgs(options.args);
    run.has_side_effects = true; // Completion receipts belong to each invocation, never a cached process outcome.
    return run;
}
pub const LintOptions = struct { sources: []const std.Build.LazyPath, config: ?std.Build.LazyPath = null, directories: []const std.Build.LazyPath = &.{}, inputs: []const std.Build.LazyPath = &.{}, args: []const []const u8 = &.{} };
