const std = @import("std");
const zon = @import("build.zig.zon");

/// What a project that depends on glint builds: the `glint` module, the `glint`
/// program, and `addLinter` and `addLint` for a project's own linter.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const aegis_dependency = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    const aegis = aegis_dependency.module("aegis");
    const module = b.addModule("glint", .{ .root_source_file = b.path("src/glint.zig"), .target = target, .optimize = optimize });
    module.addImport("aegis", aegis);
    module.addImport("release", release(b));

    const executable = b.addExecutable(.{ .name = "glint", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glint", .module = module }},
    }) });
    executable.root_module.addImport("aegis", aegis);
    b.installArtifact(executable);
}

/// glint's development: its tests, checks, linter examples and benchmarks under
/// preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("glint", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const module = package.module("glint");
    const executable = package.artifact("glint");
    const aegis_dependency = p.dependency("aegis", .{ .target = target, .optimize = optimize });
    const aegis = aegis_dependency.module("aegis");
    const portable = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const portable_tokens = b.createModule(.{ .root_source_file = p.path("src/Token.zig"), .target = portable, .optimize = .small });
    const portable_contract = b.addObject(.{ .name = "token-portable", .root_module = b.createModule(.{
        .root_source_file = p.path("ci/token_portable.zig"),
        .target = portable,
        .optimize = .small,
        .imports = &.{.{ .name = "token", .module = portable_tokens }},
    }) });
    b.step("check-token-portable", "Compile the std-only token API at a different pointer width").dependOn(&portable_contract.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = p.path("src/tests.zig"), .target = target, .optimize = optimize }), .filters = if (filter) |f| &.{f} else &.{} });
    tests.root_module.addImport("aegis", aegis);
    tests.root_module.addImport("glint", module);
    tests.root_module.addImport("aegis_sources", aegisSources(b, p, module, aegis_dependency, target));
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    tests.root_module.addImport("shakedown", shakedown.module("shakedown"));
    const test_step = b.step("test", "Run selected contract tests and benchmark smoke");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const library_tests = b.addTest(.{ .root_module = module, .filters = if (filter) |f| &.{f} else &.{} });
    test_step.dependOn(&b.addRunArtifact(library_tests).step);
    const project_linter = b.addExecutable(.{ .name = "glint-project-example", .root_module = b.createModule(.{
        .root_source_file = p.path("examples/project.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glint", .module = module }},
    }) });
    const project_check = b.step("check-project", "Compile a standalone linter with project-owned rules");
    project_check.dependOn(&project_linter.step);
    const project_smoke = addLint(b, project_linter, .{ .sources = &.{p.path("examples/report.zig")}, .directories = &.{p.path("examples")}, .args = &.{ "--only", "LOCAL_EXPORT" } });
    const source_policy = addLint(b, executable, .{
        .sources = &.{
            p.path("src/AegisContract.zig"),
            p.path("src/AegisPack.zig"),
            p.path("src/AegisPack_test.zig"),
            p.path("src/BuildGate.zig"),
            p.path("src/Builtins.zig"),
            p.path("src/Completion.zig"),
            p.path("src/DeadDeclarations.zig"),
            p.path("src/Facts.zig"),
            p.path("src/File.zig"),
            p.path("src/Library.zig"),
            p.path("src/Library_test.zig"),
            p.path("src/Model.zig"),
            p.path("src/Project.zig"),
            p.path("src/Projection.zig"),
            p.path("src/Projection_test.zig"),
            p.path("src/Token.zig"),
            p.path("src/Token/liveness.zig"),
            p.path("src/Token/store.zig"),
            p.path("src/Token/data.zig"),
            p.path("src/Token_test.zig"),
            p.path("src/Report.zig"),
            p.path("src/Result.zig"),
            p.path("src/Rule.zig"),
            p.path("src/RuleContext.zig"),
            p.path("src/RuleContext_test.zig"),
            p.path("src/Runner.zig"),
            p.path("src/Runner_test.zig"),
            p.path("src/Suppression.zig"),
            p.path("src/build_gate_test.zig"),
            p.path("src/cli.zig"),
            p.path("src/cli_test.zig"),
            p.path("src/contract_test.zig"),
            p.path("src/glint.zig"),
            p.path("src/main.zig"),
            p.path("src/names.zig"),
            p.path("src/tests.zig"),
        },
        .directories = &.{p.path("src")},
        .args = &.{ "--only", "P001", "--only", "P002", "--only", "P003", "--gate", "P001", "--gate", "P002", "--gate", "P003" },
    });
    b.step("check-source-policy", "Verify complete all-cast, safety-off and length policy on explicit own inputs").dependOn(&source_policy.step);
    const helper_check = b.step("check-helper", "Verify the public helper's exact source and directory inputs");
    helper_check.dependOn(&project_smoke.step);
    const portable_smoke = b.addRunArtifact(project_linter);
    portable_smoke.addArgs(&.{ "--only", "LOCAL_EXPORT", "examples/input.zig" });
    portable_smoke.addFileInput(p.path("examples/input.zig"));
    test_step.dependOn(&portable_smoke.step);
    const check = b.step("check", "Compile CLI and tests");
    check.dependOn(&tests.step);
    check.dependOn(&executable.step);
    check.dependOn(&project_linter.step);
    tools.preflight.addCi(b, p, .{ .tests = test_step, .portable_tests = true, .bench = .{
        .programs = &.{ .{ .name = "glint-scan", .source = "bench/scan.zig" }, .{ .name = "glint-aegis", .source = "bench/aegis.zig" } },
        .imports = benchImports,
        .target = target,
        .optimize = optimize,
    } });
    tools.preflight.addConsumerCheck(b, p, .{ .package = "glint", .program = p.path("ci/consumer.zig"), .modules = &.{"glint"}, .packages = &.{aegis_dependency} });
}

/// glint's version, as its manifest names it, for what glint reports about itself
/// (SARIF's `tool.driver.version`). Made in `b`, the build that owns glint's sources.
fn release(b: *std.Build) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    return options.createModule();
}

/// `b` is the development build.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const p = b.dependency("glint", .{ .target = target, .optimize = optimize }).builder;
    const module = b.createModule(.{ .root_source_file = p.path("src/glint.zig"), .target = target, .optimize = optimize });
    const aegis_dependency = p.dependency("aegis", .{ .target = target, .optimize = optimize });
    module.addImport("aegis", aegis_dependency.module("aegis"));
    module.addImport("release", release(p));
    return b.allocator.dupe(std.Build.Module.Import, &.{ .{ .name = "glint", .module = module }, .{ .name = "aegis_sources", .module = aegisSources(b, p, module, aegis_dependency, target) } }) catch @panic("OOM");
}

/// The pinned aegis files that publish the pack's members, embedded as sources to analyze.
fn aegisSources(b: *std.Build, p: *std.Build, glint: *std.Build.Module, aegis_dependency: *std.Build.Dependency, target: std.Build.ResolvedTarget) *std.Build.Module {
    const sources = b.createModule(.{ .root_source_file = p.path("ci/aegis_sources.zig"), .target = target });
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
        .{ "aegis-blocking-guarded", "src/BlockingGuarded.zig" },
        .{ "aegis-rw-guarded", "src/RwGuarded.zig" },
        .{ "aegis-spin-rw-guarded", "src/SpinRwGuarded.zig" },
        .{ "aegis-condition", "src/Condition.zig" },
        .{ "aegis-once", "src/Once.zig" },
        .{ "aegis-lazy", "src/Lazy.zig" },
        .{ "aegis-confined", "src/Confined.zig" },
        .{ "aegis-atomic", "src/Atomic.zig" },
        .{ "aegis-order", "src/Order.zig" },
        .{ "aegis-bounded", "src/bounded.zig" },
        .{ "aegis-own", "src/own.zig" },
        .{ "aegis-shared", "src/Shared.zig" },
        .{ "aegis-input", "src/input.zig" },
        .{ "aegis-secret-value", "src/secret/value.zig" },
        .{ "aegis-state", "src/state.zig" },
        .{ "aegis-state-edge", "src/state/edge.zig" },
        .{ "aegis-state-machine", "src/state/machine.zig" },
        .{ "aegis-state-stage", "src/state/stage.zig" },
        .{ "aegis-state-runtime", "src/state/runtime.zig" },
        .{ "aegis-scope", "src/scope.zig" },
        .{ "aegis-scope-table", "src/scope/table.zig" },
        .{ "aegis-scope-ref", "src/scope/ref.zig" },
        .{ "aegis-scope-slot", "src/scope/slot.zig" },
        .{ "aegis-handle", "src/handle.zig" },
        .{ "aegis-handle-pool", "src/handle/pool.zig" },
        .{ "aegis-handle-slot-map", "src/handle/slot_map.zig" },
        .{ "aegis-handle-dense", "src/handle/dense.zig" },
        .{ "aegis-handle-secondary", "src/handle/secondary.zig" },
        .{ "aegis-handle-domain", "src/handle/Domain.zig" },
        .{ "aegis-handle-index", "src/handle/index.zig" },
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
        .imports = &.{.{ .name = "glint", .module = dependency.module("glint") }},
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
    run.addArtifactArg2(executable, .{});
    run.addDirectoryArg2(b.tmpPath(), .{});
    if (options.config) |config| {
        run.addArg("--config");
        run.addFileArg(config);
    }
    for (options.sources) |source| run.addFileArg(source);
    for (options.directories) |directory| {
        run.addArg("--input-directory");
        run.addDirectoryArg2(directory, .{});
    }
    for (options.inputs) |input| run.addFileInput(input);
    run.addArgs(options.args);
    run.has_side_effects = true; // Completion receipts belong to each invocation, never a cached process outcome.
    return run;
}
pub const LintOptions = struct { sources: []const std.Build.LazyPath, config: ?std.Build.LazyPath = null, directories: []const std.Build.LazyPath = &.{}, inputs: []const std.Build.LazyPath = &.{}, args: []const []const u8 = &.{} };
