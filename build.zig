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
    module.addImport("ensign", b.dependency("ensign", .{ .target = target, .optimize = optimize }).module("ensign"));
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
    const soundness_jobs = b.option(usize, "soundness-jobs", "The workers the soundness suite judges its cases on (default: one per CPU)") orelse 0;
    const soundness_rules = b.option([]const u8, "soundness-rules", "The rules whose soundness cases alone run, by comma (default: every rule's)");
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
    const test_step = b.step("test", "Run selected contract tests and benchmark smoke");
    const check = b.step("check", "Compile CLI and tests");
    // The contract tests, in a few roots that compile and run as parallel steps.
    const test_imports = [_]std.Build.Module.Import{
        .{ .name = "aegis", .module = aegis },
        .{ .name = "glint", .module = module },
        .{ .name = "aegis_sources", .module = aegisSources(b, p, module, aegis_dependency, target) },
        .{ .name = "shakedown", .module = b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown") },
    };
    for ([_][]const u8{ "src/tests.zig", "src/test_danger.zig", "src/test_pack.zig" }) |root| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = p.path(root), .target = target, .optimize = optimize, .imports = &test_imports }), .filters = if (filter) |f| &.{f} else &.{} });
        test_step.dependOn(&b.addRunArtifact(tests).step);
        check.dependOn(&tests.step);
    }
    const library_tests = b.addTest(.{ .root_module = module, .filters = if (filter) |f| &.{f} else &.{} });
    test_step.dependOn(&b.addRunArtifact(library_tests).step);
    // The soundness suite: every case under test/soundness/ on the glint just built, std from
    // this Zig and aegis as glint pins it, each case compiled by this Zig first. Its glint is ReleaseSafe whatever `-Doptimize` says:
    // the suite runs glint over every case, which costs about 8 times the CPU in Debug, and
    // ReleaseSafe keeps every safety check.
    const soundness_optimize = b.option(std.lang.Optimize, "soundness-optimize", "The mode the soundness suite's glint is built in (default: ReleaseSafe)") orelse .safe;
    const soundness_package = b.dependency("glint", .{ .target = target, .optimize = soundness_optimize });
    const soundness = b.addExecutable(.{ .name = "glint-soundness", .root_module = b.createModule(.{
        .root_source_file = p.path("test/soundness/run.zig"),
        .target = target,
        .optimize = soundness_optimize,
        .imports = &.{.{ .name = "glint", .module = soundness_package.module("glint") }},
    }) });
    const soundness_run = b.addRunArtifact(soundness);
    soundness_run.addDirectoryArg2(p.path("test/soundness"), .{});
    soundness_run.addFileArg2(.zig_exe, .{});
    soundness_run.addDirectoryArg2(.zig_lib, .{});
    soundness_run.addFileArg2(aegis_dependency.path("src/root.zig"), .{});
    soundness_run.addArg(b.fmt("{d}", .{soundness_jobs}));
    if (soundness_rules) |list| soundness_run.addArg(list);
    test_step.dependOn(&soundness_run.step);
    const soundness_tests = b.addTest(.{ .root_module = soundness.root_module });
    test_step.dependOn(&b.addRunArtifact(soundness_tests).step);
    check.dependOn(&soundness_tests.step);
    b.step("soundness", "Run the soundness suite alone").dependOn(&soundness_run.step);
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
            p.path("src/Metrics.zig"),
            p.path("src/AegisRecursion.zig"),
            p.path("src/Facts.zig"),
            p.path("src/File.zig"),
            p.path("src/Library.zig"),
            p.path("src/Library_test.zig"),
            p.path("src/Model.zig"),
            p.path("src/Project.zig"),
            p.path("src/releases.zig"),
            p.path("src/Disallowed.zig"),
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
            p.path("src/Summary.zig"),
            p.path("src/Summary_test.zig"),
            p.path("src/build_gate_test.zig"),
            p.path("src/cli.zig"),
            p.path("src/cli_test.zig"),
            p.path("src/contract_test.zig"),
            p.path("src/glint.zig"),
            p.path("src/main.zig"),
            p.path("src/names.zig"),
            p.path("src/tests.zig"),
            p.path("src/test_danger.zig"),
            p.path("src/test_pack.zig"),
        },
        .directories = &.{p.path("src")},
        .args = &.{ "--only", "P003", "--gate", "P003" },
    });
    b.step("check-source-policy", "Verify complete all-cast, safety-off and length policy on explicit own inputs").dependOn(&source_policy.step);
    // glint's rules read values, writes, calls and types only through the shared queries: the
    // rule side of glint's sources (`ruleSources`, read from the tree), with std, aegis and the
    // shared queries' files resolved and not checked.
    const rule_readers = b.addExecutable(.{ .name = "glint-rule-readers", .root_module = b.createModule(.{
        .root_source_file = p.path("ci/rule_readers.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glint", .module = module }},
    }) });
    const rule_files = ruleSources(b, p) catch |err| std.debug.panic("glint's src/ could not be listed for RULE_READERS: {t}", .{err});
    const rule_lint = addLint(b, rule_readers, .{ .sources = rule_files, .directories = &.{p.path("src")}, .args = &.{ "--only", "RULE_READERS" } });
    rule_lint.addArg("--zig-lib-path");
    rule_lint.addDirectoryArg2(.zig_lib, .{});
    rule_lint.addArg("--module");
    rule_lint.addPrefixedFileArg("aegis=", aegis_dependency.path("src/root.zig"));
    // NAME_TABLES over every source of glint's own, the shared queries' files included: a table
    // of declarations by their text is the class wherever it is made.
    const table_lint = addLint(b, rule_readers, .{ .sources = ownSources(b, p) catch |err| std.debug.panic("glint's src/ could not be listed for NAME_TABLES: {t}", .{err}), .directories = &.{p.path("src")}, .args = &.{ "--only", "NAME_TABLES" } });
    table_lint.addArg("--zig-lib-path");
    table_lint.addDirectoryArg2(.zig_lib, .{});
    table_lint.addArg("--module");
    table_lint.addPrefixedFileArg("aegis=", aegis_dependency.path("src/root.zig"));
    const rule_readers_step = b.step("check-rule-readers", "Report where a rule reads a value, a write, a call or a type around the shared queries, and where glint keys a table by text: each report whole under zig-out/rule-readers/, their totals per rule, class and file printed");
    // Each report whole in a file, never read off the build runner's output, which it cuts.
    const reports = [_]struct { std.Build.LazyPath, []const u8 }{ .{ rule_lint.captureStdOut(.{}), "rule-readers.json" }, .{ table_lint.captureStdOut(.{}), "name-tables.json" } };
    const totals = b.addRunArtifact(b.addExecutable(.{ .name = "glint-rule-readers-totals", .root_module = b.createModule(.{
        .root_source_file = p.path("ci/rule_readers_totals.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "aegis", .module = p.dependency("aegis", .{ .target = b.graph.host, .optimize = .fast }).module("aegis") }},
    }) }));
    for (reports) |report| {
        rule_readers_step.dependOn(&b.addInstallFile(report[0], b.fmt("rule-readers/{s}", .{report[1]})).step);
        totals.addFileArg(report[0]);
    }
    rule_readers_step.dependOn(&totals.step);
    const rule_readers_tests = b.addTest(.{ .root_module = rule_readers.root_module, .filters = if (filter) |f| &.{f} else &.{} });
    test_step.dependOn(&b.addRunArtifact(rule_readers_tests).step);
    check.dependOn(&rule_readers.step);
    const helper_check = b.step("check-helper", "Verify the public helper's exact source and directory inputs");
    helper_check.dependOn(&project_smoke.step);
    // The project linter on each test platform, over its own source, which its rule passes.
    const portable_smoke = b.addRunArtifact(project_linter);
    portable_smoke.addArgs(&.{ "--only", "LOCAL_EXPORT", "examples/project.zig" });
    portable_smoke.addFileInput(p.path("examples/project.zig"));
    test_step.dependOn(&portable_smoke.step);
    check.dependOn(&executable.step);
    check.dependOn(&project_linter.step);
    tools.preflight.addCi(b, p, .{ .tests = test_step, .portable_tests = true, .bench = .{
        .programs = &.{ .{ .name = "glint-scan", .source = "bench/scan.zig" }, .{ .name = "glint-aegis", .source = "bench/aegis.zig" } },
        .imports = benchImports,
        .target = target,
        .optimize = optimize,
    } });
    // The packages a consumer's build reaches through glint's manifest.
    const ensign_dependency = p.dependency("ensign", .{ .target = target, .optimize = optimize });
    const packages = [_]*std.Build.Dependency{ aegis_dependency, ensign_dependency, ensign_dependency.builder.dependency("xenoglyph", .{ .target = target, .optimize = optimize }), ensign_dependency.builder.dependency("aegis", .{ .target = target, .optimize = optimize }) };
    tools.preflight.addConsumerCheck(b, p, .{ .package = "glint", .program = p.path("ci/consumer.zig"), .modules = &.{"glint"}, .packages = &packages });
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
    module.addImport("ensign", p.dependency("ensign", .{ .target = target, .optimize = optimize }).module("ensign"));
    module.addImport("release", release(p));
    return b.allocator.dupe(std.Build.Module.Import, &.{ .{ .name = "glint", .module = module }, .{ .name = "aegis_sources", .module = aegisSources(b, p, module, aegis_dependency, target) } }) catch @panic("OOM");
}

/// The pinned aegis revision's whole `src/` tree, embedded as sources to analyze: a generated
/// `aegis_tree` module lists each file by its path in aegis's package, read from the tree, so a
/// file aegis adds is embedded too and `ci/aegis_sources.zig` derives each import from it.
fn aegisSources(b: *std.Build, p: *std.Build, glint: *std.Build.Module, aegis_dependency: *std.Build.Dependency, target: std.Build.ResolvedTarget) *std.Build.Module {
    const sources = b.createModule(.{ .root_source_file = p.path("ci/aegis_sources.zig"), .target = target });
    sources.addImport("glint", glint);
    const paths = treeSources(b, aegis_dependency.builder) catch |err| std.debug.panic("aegis src/: {t}", .{err});
    var listing: std.Io.Writer.Allocating = .init(b.allocator);
    const out = &listing.writer;
    out.writeAll("//! Generated by glint's build.zig (aegisSources): aegis's src/ tree, by path.\n") catch @panic("OOM");
    out.writeAll("pub const files = [_]struct { name: []const u8, bytes: [:0]const u8 }{\n") catch @panic("OOM");
    for (paths) |path| out.print("    .{{ .name = \"src/{s}\", .bytes = @embedFile(\"aegis/{s}\") }},\n", .{ path, path }) catch @panic("OOM");
    out.writeAll("};\n") catch @panic("OOM");
    const tree = b.createModule(.{ .root_source_file = b.addWriteFiles().add("aegis_tree.zig", listing.written()), .target = target });
    for (paths) |path| tree.addAnonymousImport(b.fmt("aegis/{s}", .{path}), .{ .root_source_file = aegis_dependency.path(b.fmt("src/{s}", .{path})), .target = target });
    sources.addImport("aegis_tree", tree);
    return sources;
}

/// Every Zig source under a package's `src/`, by its path there, in order.
fn treeSources(b: *std.Build, package: *std.Build) ![]const []const u8 {
    const io = b.graph.io;
    var dir = try package.root.openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(b.allocator);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try paths.append(b.allocator, try b.allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    return paths.items;
}

/// Builds a project's linter with statically compiled Zig rules and the standalone CLI.
/// Every Zig source of glint's own under `src/`, test files aside, in order: read from the tree,
/// so a file added later is read too.
fn ownSources(b: *std.Build, p: *std.Build) ![]const std.Build.LazyPath {
    var found: std.ArrayList(std.Build.LazyPath) = .empty;
    for (try ownSourcePaths(b, p)) |path| try found.append(b.allocator, p.path(path));
    return found.items;
}
/// The paths of `ownSources`, from the package root (`src/Facts.zig`).
fn ownSourcePaths(b: *std.Build, p: *std.Build) ![]const []const u8 {
    const io = b.graph.io;
    var dir = try p.root.openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(b.allocator);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or std.mem.endsWith(u8, entry.path, "_test.zig")) continue;
        try paths.append(b.allocator, b.fmt("src/{s}", .{entry.path}));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    return paths.items;
}
/// The rule side of glint's sources, for the rule readers' guard: every one of `ownSources` but the
/// test roots, the files of the layers that hold no rules and the shared queries (ci/layer_files.zig),
/// so a file added later is read unless it is placed in one of those.
fn ruleSources(b: *std.Build, p: *std.Build) ![]const std.Build.LazyPath {
    const layer_files = @import("ci/layer_files.zig");
    var found: std.ArrayList(std.Build.LazyPath) = .empty;
    each: for (try ownSourcePaths(b, p)) |path| {
        if (std.mem.startsWith(u8, std.Io.Dir.path.basename(path), "test_")) continue;
        for (layer_files.shared_queries) |query| if (std.mem.eql(u8, path, query)) continue :each;
        for (layer_files.layers) |layer| {
            if (std.mem.eql(u8, layer.name, layer_files.rules_layer)) continue;
            for (layer.patterns) |pattern| if (layerHolds(pattern, path)) continue :each;
        }
        try found.append(b.allocator, p.path(path));
    }
    return found.items;
}
/// Whether a layer's pattern names `path`: the file itself, or a directory's files (`src/Token/**`).
fn layerHolds(pattern: []const u8, path: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "/**")) return std.mem.startsWith(u8, path, pattern[0 .. pattern.len - 2]);
    return std.mem.eql(u8, pattern, path);
}

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
        .imports = &.{
            .{ .name = "glint", .module = module },
            .{ .name = "ensign", .module = module.import_table.get("ensign") orelse @panic("glint must import ensign") },
            .{ .name = "aegis", .module = module.import_table.get("aegis") orelse @panic("glint must import aegis") },
        },
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
