//! Filesystem front end for explicit inputs. No globs, build execution or hidden cache.
const std = @import("std");
const Project = @import("Project.zig");
const Rule = @import("Rule.zig");
const AegisPack = @import("AegisPack.zig");
const Report = @import("Report.zig");
const RuleContext = @import("RuleContext.zig");
const Runner = @import("Runner.zig");
const Result = @import("Result.zig");
const aegis = @import("aegis");
const ensign = @import("ensign");
const release = @import("release");
const Cli = @This();

const Module = struct { name: []const u8, path: []const u8 };
const Options = struct {
    config: Rule.Config = .{},
    format: Report.Format = .text,
    files: std.ArrayList([]const u8) = .empty,
    modules: std.ArrayList(Module) = .empty,
    /// Directories whose files belong to a named package (`Project.Input.package`).
    packages: std.ArrayList(Module) = .empty,
    roots: std.ArrayList([]const u8) = .empty,
    zig_lib_path: ?[]const u8 = null,
};

const Loader = struct {
    a: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    inputs: std.ArrayList(Project.Input) = .empty,
    mappings: std.ArrayList(Project.Import) = .empty,
    paths: std.StringHashMapUnmanaged(Project.FileId) = .empty,
    canonical_paths: std.ArrayList([]const u8) = .empty,
    roots: std.ArrayList([]const u8) = .empty,
    /// Package directories, canonical.
    packages: std.ArrayList(Module) = .empty,
    bytes: usize = 0,

    fn load(self: *Loader, path: []const u8, selected: bool) !Project.FileId {
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.a);
        if (self.paths.get(canonical)) |id| {
            if (selected) self.inputs.items[id.raw()].selected = true; // safe: enum identities index their owning frozen tables without narrowing.
            return id;
        }
        if (self.inputs.items.len >= 4096) return error.FileBudgetExceeded;
        if (!selected) {
            var permitted = false;
            for (self.roots.items) |root| if (within(root, canonical)) {
                permitted = true;
                break;
            };
            if (!permitted) return error.ImportOutsideRoots;
        }
        const read = try std.Io.Dir.cwd().readFileAllocOptions(self.io, canonical, self.a, .limited(16 * 1024 * 1024), .@"1", 0);
        // A file's bytes are input until the project's budget has taken them.
        const source = try aegis.input.Untrusted([:0]const u8).init(read).parse(self, Loader.take);
        const bytes = source.bytes;
        const id: Project.FileId = Project.FileId.fromRaw(@intCast(self.inputs.items.len)); // aegis: no-danger: the loader bounds source count to 4096 before creating u32 identities.
        const basename = std.Io.Dir.path.basename(path);
        const stem = if (std.mem.endsWith(u8, basename, ".zig")) basename[0 .. basename.len - 4] else basename;
        try self.inputs.append(self.a, .{ .name = path, .stem = stem, .bytes = bytes, .selected = selected, .package = self.packageOf(canonical) });
        try self.canonical_paths.append(self.a, canonical);
        try self.paths.put(self.a, canonical, id);
        return id;
    }

    /// A file's bytes, counted against the project's source budget.
    const Source = struct { bytes: [:0]const u8 };
    fn take(self: *Loader, bytes: [:0]const u8) error{SourceBudgetExceeded}!Source {
        self.bytes += bytes.len;
        if (self.bytes > 128 * 1024 * 1024) return error.SourceBudgetExceeded;
        return .{ .bytes = bytes };
    }

    /// The package of the innermost directory holding `canonical`; empty when none does.
    fn packageOf(self: *const Loader, canonical: []const u8) []const u8 {
        var best: ?Module = null;
        for (self.packages.items) |package| if (within(package.path, canonical)) {
            if (best == null or package.path.len > best.?.path.len) best = package;
        };
        return if (best) |package| package.name else "";
    }

    fn imports(self: *Loader) !void {
        var cursor: usize = 0;
        while (cursor < self.inputs.items.len) : (cursor += 1) {
            const from: Project.FileId = Project.FileId.fromRaw(@intCast(cursor)); // aegis: no-danger: the loader bounds source count to 4096 before creating u32 identities.
            const bytes = self.inputs.items[cursor].bytes;
            const sentinel = try self.a.dupeSentinel(u8, bytes, 0);
            var lexer: std.zig.Tokenizer = .init(sentinel);
            // Discovery only: actual semantics comes from each model's AST/ZIR.
            while (true) {
                const token = lexer.next();
                if (token.tag == .eof) break;
                if (token.tag != .builtin or !std.mem.eql(u8, sentinel[token.loc.start..token.loc.end], "@import")) continue;
                if (lexer.next().tag != .l_paren) continue;
                const literal = lexer.next();
                if (literal.tag != .string_literal) continue;
                const spelling = try std.zig.string_literal.parseAlloc(self.a, sentinel[literal.loc.start..literal.loc.end]);
                if (lexer.next().tag != .r_paren) continue;
                const target_path = try self.importPath(cursor, spelling) orelse continue;
                const target = try self.load(target_path, false);
                var duplicate = false;
                for (self.mappings.items) |m| if (m.from.eql(from) and std.mem.eql(u8, m.spelling, spelling)) {
                    duplicate = true;
                    break;
                };
                if (!duplicate) try self.mappings.append(self.a, .{ .from = from, .spelling = spelling, .target = target });
            }
        }
    }

    fn importPath(self: *Loader, from: usize, spelling: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, spelling, "std")) {
            const lib = self.options.zig_lib_path orelse return null;
            const path = try std.Io.Dir.path.join(self.a, &.{ lib, "std", "std.zig" });
            return path;
        }
        for (self.options.modules.items) |module| if (std.mem.eql(u8, spelling, module.name)) return module.path;
        if (!std.mem.endsWith(u8, spelling, ".zig")) return null;
        const path = try std.Io.Dir.path.join(self.a, &.{ std.Io.Dir.path.dirname(self.canonical_paths.items[from]) orelse ".", spelling });
        return path;
    }
};

fn within(root: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, root, path) or (root.len == 1 and std.Io.Dir.path.isSep(root[0]) and std.Io.Dir.path.isAbsolute(path)) or (std.mem.startsWith(u8, path, root) and path.len > root.len and std.Io.Dir.path.isSep(path[root.len]));
}

/// What a caller asks of the run before its line is read: a record of how the run went, at
/// `--result`, so a line glint refuses still leaves one. It comes first; the rest of the line
/// is glint's own (`Arguments`).
const Request = struct {
    result: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
    arguments: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{
        .name = "glint",
        .help = null,
        .options = .{
            .result = .{ .value_name = "FILE", .hint = .file, .help = "Write the run's record here" },
            .run_id = .{ .value_name = "ID", .help = "The run's name in its record" },
            .arguments = .{ .positional = true, .raw = true, .value_name = "ARGUMENT" },
        },
    };
};

/// glint's command line, read from this declaration by ensign: the rules and their levels,
/// the code options, and the files with what their imports reach.
pub const Arguments = struct {
    files: []const []const u8 = &.{},
    only: []const []const u8 = &.{},
    reviewed: bool = false,
    family: bool = false,
    config: ?[]const u8 = null,
    report: []const []const u8 = &.{},
    gate: []const []const u8 = &.{},
    disable: []const []const u8 = &.{},
    format: Report.Format = .text,
    max_line_length: ?u32 = null,
    max_function_lines: ?u32 = null,
    fact_budget: ?usize = null,
    strict_suppressions: bool = false,
    metrics: bool = false,
    zig_lib_path: ?[]const u8 = null,
    module: []const []const u8 = &.{},
    root: []const []const u8 = &.{},
    package: []const []const u8 = &.{},
    files_from: []const []const u8 = &.{},
    input_directory: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{
        .name = "glint",
        .version = release.version,
        .about = "A linter for Zig on Zig's own parser and semantic form",
        .description = "Explicit files only: no path patterns, no build.zig execution. The rules start from Z003 and Z013, or from --only, --reviewed, --family or --config; --report, --gate and --disable then set a rule's level. A caller that wants the run's record names it first: --result FILE --run-id ID. Suppress one site with // glint-ignore: Z013 -- written reason. Exit: 0 complete and clean; 1 findings; 2 input, tool or incomplete analysis.",
        .options = .{
            .files = .{ .positional = true, .value_name = "FILE", .hint = .file, .help = "A file to check" },
            .only = .{ .value_name = "ID", .section = "Rules", .help = "Check only this rule, repeated, at report level" },
            .reviewed = .{ .negatable = false, .section = "Rules", .help = "Every retained rule, at report level" },
            .family = .{ .negatable = false, .section = "Rules", .help = "The family's reporting profile" },
            .config = .{ .value_name = "FILE", .hint = .file, .section = "Rules", .help = "A JSON policy: its profile, rule levels and code options" },
            .report = .{ .value_name = "ID", .section = "Rules", .help = "Report this rule, repeated" },
            .gate = .{ .value_name = "ID", .section = "Rules", .help = "Gate on this rule, repeated: a finding fails the run" },
            .disable = .{ .value_name = "ID", .section = "Rules", .help = "Leave this rule out, repeated" },
            .format = .{ .help = "How the report is written" },
            .max_line_length = .{ .value_name = "N", .help = "The line length Z024's readability report allows, in bytes; 100 by default" },
            .max_function_lines = .{ .value_name = "N", .help = "The lines P003 allows a function; 120 by default" },
            .fact_budget = .{ .value_name = "N", .help = "How many facts a file's analysis may resolve; 100000 by default" },
            .strict_suppressions = .{ .negatable = false, .help = "A suppression that suppresses nothing makes the run incomplete" },
            .metrics = .{ .negatable = false, .help = "Count each file's functions and assertion calls into the report" },
            .zig_lib_path = .{ .value_name = "DIR", .hint = .directory, .section = "Inputs", .help = "Zig's library, for std's imports" },
            .module = .{ .value_name = "NAME=FILE", .section = "Inputs", .help = "A module the files import by name, and its root file, repeated" },
            .root = .{ .value_name = "DIR", .hint = .directory, .section = "Inputs", .help = "A directory imports may read files from, repeated" },
            .package = .{ .value_name = "NAME=DIR", .section = "Inputs", .help = "The package whose files a directory holds, repeated" },
            .files_from = .{ .value_name = "FILE", .hint = .file, .section = "Inputs", .help = "A file naming files to check, one a line, repeated" },
            .input_directory = .{ .value_name = "DIR", .hint = .directory, .hidden = true, .help = "A directory the caller's build reads; never a selection of files" },
        },
        .conflicts = &.{&.{ .only, .reviewed, .family, .config }},
    };
};

/// What the arguments ask: the rules from the profile chosen, then each rule's level as asked.
fn options(a: std.mem.Allocator, io: std.Io, arguments: Arguments, definitions: []const Rule.Definition) !Options {
    var result: Options = .{ .format = arguments.format, .zig_lib_path = arguments.zig_lib_path };
    if (arguments.config) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024));
        // A configuration file is the checked repository's content: input until parsed.
        result.config = try aegis.input.Untrusted([]const u8).init(bytes).parse(Configuring{ .a = a, .definitions = definitions }, configure);
    } else if (arguments.reviewed) {
        result.config = Rule.Config.reviewed();
    } else if (arguments.family) {
        result.config = Rule.Config.family();
    } else if (arguments.only.len != 0) {
        result.config = Rule.Config.none();
        for (arguments.only) |id| try select(a, &result.config, Rule.parseConfigured(id, definitions) orelse return error.UnknownRule, .report);
    }
    const levels = [_]struct { []const []const u8, Rule.Config.Level }{ .{ arguments.report, .report }, .{ arguments.gate, .gate }, .{ arguments.disable, .off } };
    for (levels) |level| for (level[0]) |id| try select(a, &result.config, Rule.parseConfigured(id, definitions) orelse return error.UnknownRule, level[1]);
    if (arguments.max_line_length) |n| result.config.max_line_length = n;
    if (arguments.max_function_lines) |n| result.config.max_function_lines = n;
    if (arguments.fact_budget) |n| result.config.fact_budget = n;
    if (arguments.strict_suppressions) result.config.strict_suppressions = true;
    if (arguments.metrics) result.config.metrics = true;
    try result.roots.appendSlice(a, arguments.root);
    for (arguments.module) |mapping| try result.modules.append(a, named(mapping) orelse return error.InvalidModule);
    for (arguments.package) |mapping| try result.packages.append(a, named(mapping) orelse return error.InvalidPackage);
    try result.files.appendSlice(a, arguments.files);
    for (arguments.files_from) |from| {
        const read = try std.Io.Dir.cwd().readFileAlloc(io, from, a, .limited(4 * 1024 * 1024));
        const list = try aegis.input.Untrusted([]const u8).init(read).parse(a, fileList);
        try result.files.appendSlice(a, list.paths);
    }
    return result;
}

/// The files a `--files-from` list names, one a line, blank lines aside.
const FileList = struct { paths: []const []const u8 };
fn fileList(a: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!FileList {
    var paths: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, "\r");
        if (path.len > 0) try paths.append(a, path);
    }
    return .{ .paths = paths.items };
}

/// `NAME=VALUE`, neither empty.
fn named(mapping: []const u8) ?Module {
    const equals = std.mem.findScalar(u8, mapping, '=') orelse return null;
    if (equals == 0 or equals + 1 == mapping.len) return null;
    return .{ .name = mapping[0..equals], .path = mapping[equals + 1 ..] };
}

/// Runs glint on `args`, the program's name first: the report, help or version to `writer`,
/// a mistake in the arguments to `problems`.
pub fn execute(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer, problems: *std.Io.Writer) !u8 {
    return executeConfigured(gpa, io, args, writer, problems, &AegisPack.rules);
}
/// Standalone CLI for compiled project rules. Same completion and output contract.
pub fn executeConfigured(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer, problems: *std.Io.Writer, project_rules: []const RuleContext.Rule) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostic: ensign.Diagnostic = .{};
    const line = if (args.len == 0) args else args[1..];
    const request = switch (ensign.parse(Request, a, line, .{ .diagnostic = &diagnostic }) catch |err| return refused(err, diagnostic, problems)) {
        .parsed => |parsed| parsed,
        // `Request` leaves `--help` to the arguments and has no version.
        .help, .version => unreachable,
    };
    const requested = try Result.request(request.result, request.run_id);
    var record: Result.Record = .{ .run_id = if (requested) |req| req.run_id else "", .version = 1, .completed = false, .outcome = .running, .sources = 0, .findings = 0, .suppressed = 0, .output_bytes = 0, .output_sha256 = "" };
    try Result.publish(a, io, requested, record);
    const status = executeInner(gpa, a, io, request.arguments, writer, problems, &record, project_rules) catch |err| {
        if (err == error.Canceled) record.outcome = .canceled;
        if (err == error.OutOfMemory) record.outcome = .tool_failure;
        switch (err) {
            error.SourceTooLarge, error.SourceTooComplex, error.FileBudgetExceeded, error.SourceBudgetExceeded, error.ProjectBudgetExceeded, error.SnapshotLimit => record.outcome = .analysis_incomplete,
            else => {},
        }
        try Result.publish(a, io, requested, record);
        return err;
    };
    try Result.publish(a, io, requested, record);
    return status;
}

fn executeInner(gpa: std.mem.Allocator, result_a: std.mem.Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer, problems: *std.Io.Writer, record: *Result.Record, project_rules: []const RuleContext.Rule) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    record.outcome = .argument_failure;
    const definitions = try a.alloc(Rule.Definition, project_rules.len);
    for (project_rules, 0..) |rule, i| definitions[i] = rule.definition;
    var diagnostic: ensign.Diagnostic = .{};
    const outcome = ensign.parse(Arguments, a, args, .{ .diagnostic = &diagnostic }) catch |err| return refused(err, diagnostic, problems);
    const arguments = switch (outcome) {
        .parsed => |parsed| parsed,
        .help => |page| {
            record.outcome = .output_failure;
            try page.write(writer, width);
            return told(writer, record);
        },
        .version => |version| {
            record.outcome = .output_failure;
            try version.write(writer);
            return told(writer, record);
        },
    };
    const configured = try options(a, io, arguments, definitions);
    if (configured.files.items.len == 0) return error.MissingSource;
    record.outcome = .input_failure;
    var loader: Loader = .{ .a = a, .io = io, .options = &configured };
    for (configured.packages.items) |package| try loader.packages.append(a, .{ .name = package.name, .path = try std.Io.Dir.cwd().realPathFileAlloc(io, package.path, a) });
    for (configured.roots.items) |root| try loader.roots.append(a, try std.Io.Dir.cwd().realPathFileAlloc(io, root, a));
    for (configured.files.items) |path| {
        const id = try loader.load(path, true);
        const canonical = loader.canonical_paths.items[id.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
        try loader.roots.append(a, std.Io.Dir.path.dirname(canonical) orelse canonical);
    }
    if (configured.zig_lib_path) |lib| try loader.roots.append(a, try std.Io.Dir.cwd().realPathFileAlloc(io, lib, a));
    for (configured.modules.items) |module| {
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, module.path, a);
        try loader.roots.append(a, std.Io.Dir.path.dirname(canonical) orelse canonical);
    }
    record.outcome = .traversal_failure;
    try loader.imports();
    record.outcome = .tool_failure;
    var project = try Project.init(gpa, loader.inputs.items, loader.mappings.items, .{});
    defer project.deinit();
    var report = try Runner.runConfigured(gpa, &project, configured.config, .{ .project_rules = project_rules });
    defer report.deinit();
    record.outcome = .output_failure;
    var rendered: std.Io.Writer.Allocating = .init(a);
    try report.write(&rendered.writer, &project, configured.format);
    const bytes = rendered.written();
    try writer.writeAll(bytes);
    try writer.flush();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    record.output_bytes = bytes.len;
    record.output_sha256 = try result_a.dupe(u8, &std.fmt.bytesToHex(&digest, .lower));
    for (loader.inputs.items) |input| if (input.selected) {
        record.sources += 1;
    };
    record.findings = report.diagnostics.len;
    record.suppressed = report.suppressed;
    record.completed = report.complete;
    record.outcome = if (!report.complete) .analysis_incomplete else if (report.diagnostics.len != 0) .findings else .clean;
    return if (!report.complete) 2 else if (report.diagnostics.len != 0) 1 else 0;
}

/// The width help and messages wrap to.
const width = 100;

/// Help or the version, written: the run answered and checked nothing.
fn told(writer: *std.Io.Writer, record: *Result.Record) !u8 {
    try writer.flush();
    record.outcome = .help;
    return 0;
}

/// A line ensign refuses: its message written to `problems`, and `error.InvalidArguments`.
fn refused(err: ensign.Error, diagnostic: ensign.Diagnostic, problems: *std.Io.Writer) !u8 {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    try diagnostic.write(problems, width);
    try problems.flush();
    return error.InvalidArguments;
}

test "CLI invalid selections and unknown formats fail" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownRule, options(arena.allocator(), std.testing.io, .{ .only = &.{"Z008"} }, &.{}));
    try std.testing.expectError(error.InvalidValue, ensign.parse(Arguments, arena.allocator(), &.{ "--format", "other" }, .{}));
    try std.testing.expect(within("/root", "/root/src/x.zig"));
    try std.testing.expect(!within("/root", "/root-copy/x.zig"));
}

/// Strict JSON policy, containing code options only. Callers own file selection.
pub const Configuration = struct {
    profile: enum { core, none, reviewed, family } = .core,
    rules: []const Setting = &.{},
    max_line_length: u32 = 100,
    max_function_lines: u32 = 120,
    function_exceptions: []const Rule.Config.FunctionException = &.{},
    disallowed: []const Rule.Config.Disallowed = &.{},
    strict_suppressions: bool = false,
    metrics: bool = false,
    fact_budget: usize = 100_000,
    pub const Setting = struct { id: []const u8, level: Rule.Config.Level };
};
fn select(a: std.mem.Allocator, config: *Rule.Config, id: Rule.Rule, level: Rule.Config.Level) !void {
    const selections = try a.alloc(Rule.Config.Selection, config.selections.len + 1);
    @memcpy(selections[0..config.selections.len], config.selections);
    for (selections[0..config.selections.len], 0..) |selection, i| if (selection.rule == id) {
        selections[i].level = level;
        config.selections = selections[0..config.selections.len];
        return;
    };
    selections[config.selections.len] = .{ .rule = id, .level = level };
    config.selections = selections;
}
const Configuring = struct { a: std.mem.Allocator, definitions: []const Rule.Definition };
const ConfigureError = std.json.ParseError(std.json.Scanner) || error{ InvalidSelection, UnknownRule };
fn configure(context: Configuring, bytes: []const u8) ConfigureError!Rule.Config {
    const a = context.a;
    const definitions = context.definitions;
    const document = try std.json.parseFromSliceLeaky(Configuration, a, bytes, .{});
    var config: Rule.Config = switch (document.profile) {
        .core => .{},
        .none => Rule.Config.none(),
        .reviewed => Rule.Config.reviewed(),
        .family => Rule.Config.family(),
    };
    config.max_line_length = document.max_line_length;
    config.max_function_lines = document.max_function_lines;
    config.function_exceptions = document.function_exceptions;
    config.disallowed = document.disallowed;
    config.strict_suppressions = document.strict_suppressions;
    config.metrics = document.metrics;
    config.fact_budget = document.fact_budget;
    for (document.rules, 0..) |setting, i| {
        for (document.rules[0..i]) |earlier| if (std.mem.eql(u8, setting.id, earlier.id)) return error.InvalidSelection;
        const id = Rule.parseConfigured(setting.id, definitions) orelse return error.UnknownRule;
        try select(a, &config, id, setting.level);
    }
    try config.validate();
    return config;
}
