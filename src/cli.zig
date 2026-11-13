//! Filesystem front end for explicit inputs. No globs, build execution or hidden cache.
const std = @import("std");
const Project = @import("Project.zig");
const Rule = @import("Rule.zig");
const Report = @import("Report.zig");
const RuleContext = @import("RuleContext.zig");
const Runner = @import("Runner.zig");
const Fix = @import("Fix.zig");
const Result = @import("Result.zig");
const aegis = @import("aegis");
const ensign = @import("ensign");
const release = @import("version.zig");

const Module = struct { name: []const u8, path: []const u8 };
const Options = struct {
    config: Rule.Config = .{},
    format: Report.Format = .text,
    files: std.ArrayList([]const u8) = .empty,
    modules: std.ArrayList(Module) = .empty,
    /// The roots of the modules the package exports (`Project.Input.exported`).
    exported: std.ArrayList([]const u8) = .empty,
    /// Modules whose bytes a build step makes, by name (`Project.Input.external`).
    externals: std.ArrayList([]const u8) = .empty,
    /// Directories whose files belong to a named package (`Project.Input.package`).
    packages: std.ArrayList(Module) = .empty,
    roots: std.ArrayList([]const u8) = .empty,
    zig_lib_path: ?[]const u8 = null,
    /// Apply the findings' fixes to the files they are in.
    fix: bool = false,
    /// The escapes of a run before, by which the fix names an escape in the older form.
    escapes_before: []const Fix.Escaped = &.{},
    /// The rules asked by name, resolved once the packages' own rules are read (`resolve`), in
    /// this order: the packages' rules that are on unasked, the configuration's settings,
    /// `--only`, then each level's names.
    package_defaults: bool = true,
    settings: []const Configuration.Setting = &.{},
    only: []const []const u8 = &.{},
    levels: [3]struct { []const []const u8, Rule.Config.Level } = .{ .{ &.{}, .report }, .{ &.{}, .gate }, .{ &.{}, .off } },
};

const Loader = struct {
    a: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    inputs: std.ArrayList(Project.Input) = .empty,
    mappings: std.ArrayList(Project.Import) = .empty,
    /// Each loaded file's position in `inputs`, by its canonical path.
    paths: std.StringHashMapUnmanaged(usize) = .empty,
    canonical_paths: std.ArrayList([]const u8) = .empty,
    roots: std.ArrayList([]const u8) = .empty,
    /// Package directories, canonical.
    packages: std.ArrayList(Module) = .empty,
    /// Each directory's package as its nearest `build.zig.zon` names it, found once.
    manifests: std.StringHashMapUnmanaged(?Manifest) = .empty,
    bytes: usize = 0,

    fn load(self: *Loader, path: []const u8, selected: bool) !usize {
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.a);
        if (self.paths.get(canonical)) |position| {
            if (selected) self.inputs.items[position].selected = true;
            return position;
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
        const read = try aegis.own.readFileSentinel(self.io, std.Io.Dir.cwd(), canonical, self.a, .fromRaw(16 * 1024 * 1024), 0);
        // A file's bytes are input until the project's budget has taken them.
        const source = try aegis.input.Untrusted([:0]const u8).init(read).parse(self, Loader.take);
        const bytes = source.bytes;
        const position = self.inputs.items.len;
        const basename = std.Io.Dir.path.basename(path);
        const stem = if (std.mem.endsWith(u8, basename, ".zig")) basename[0 .. basename.len - 4] else basename;
        const package = try self.packageOf(canonical);
        // An input the configuration names as test code is test code throughout (`test_inputs`).
        const classification: @FieldType(Project.Input, "classification") = if (self.options.config.testInput(path) != null) .@"test" else .production;
        try self.inputs.append(self.a, .{ .name = path, .stem = stem, .kind = if (std.mem.endsWith(u8, basename, ".zon")) .zon else .zig, .bytes = bytes, .selected = selected, .package = package.name, .fingerprint = package.fingerprint, .classification = classification });
        try self.canonical_paths.append(self.a, canonical);
        try self.paths.put(self.a, canonical, position);
        return position;
    }

    /// The bodiless input of a module a build step makes, by its name: one for the run.
    fn externalInput(self: *Loader, name: []const u8) !usize {
        const key = try self.a.print("<external {s}>", .{name});
        if (self.paths.get(key)) |position| return position;
        const position = self.inputs.items.len;
        try self.inputs.append(self.a, .{ .name = key, .stem = name, .bytes = "", .selected = false, .external = true });
        try self.canonical_paths.append(self.a, key);
        try self.paths.put(self.a, key, position);
        return position;
    }

    /// A file's bytes, counted against the project's source budget.
    const Source = struct { bytes: [:0]const u8 };
    fn take(self: *Loader, bytes: [:0]const u8) error{SourceBudgetExceeded}!Source {
        self.bytes = std.math.add(usize, self.bytes, bytes.len) catch return error.SourceBudgetExceeded;
        if (self.bytes > 128 * 1024 * 1024) return error.SourceBudgetExceeded;
        return .{ .bytes = bytes };
    }

    /// The package of the innermost directory holding `canonical`: one `--package` names, or
    /// the one the nearest `build.zig.zon` names, with its fingerprint; none where neither is.
    fn packageOf(self: *Loader, canonical: []const u8) !Manifest {
        var best: ?Module = null;
        for (self.packages.items) |package| if (within(package.path, canonical)) {
            if (best == null or package.path.len > best.?.path.len) best = package;
        };
        var dir = std.Io.Dir.path.dirname(canonical);
        while (dir) |at| : (dir = std.Io.Dir.path.dirname(at)) {
            // A named package deeper than any manifest above it: its name, no identity.
            if (best) |explicit| if (explicit.path.len > at.len) return .{ .name = explicit.name };
            const found = (try self.manifest(at)) orelse continue;
            if (best) |explicit| if (explicit.path.len == at.len) return .{ .name = explicit.name, .fingerprint = found.fingerprint };
            return found;
        }
        return .{ .name = if (best) |explicit| explicit.name else "" };
    }

    /// The package `dir/build.zig.zon` names, with its fingerprint; null where there is none.
    fn manifest(self: *Loader, dir: []const u8) !?Manifest {
        if (self.manifests.get(dir)) |known| return known;
        const path = try std.Io.Dir.path.join(self.a, &.{ dir, "build.zig.zon" });
        const found: ?Manifest = if (aegis.own.readFileSentinel(self.io, std.Io.Dir.cwd(), path, self.a, .fromRaw(1024 * 1024), 0)) |bytes|
            try Manifest.parse(self.a, bytes)
        else |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => return err,
        };
        try self.manifests.put(self.a, try self.a.dupe(u8, dir), found);
        return found;
    }

    fn imports(self: *Loader) !void {
        var cursor: usize = 0;
        while (cursor < self.inputs.items.len) : (cursor += 1) {
            const from = cursor;
            const bytes = self.inputs.items[cursor].bytes;
            const sentinel = try self.a.dupeSentinel(u8, bytes, 0);
            var lexer: std.zig.Tokenizer = .init(sentinel);
            // Discovery only: actual semantics comes from each model's AST/ZIR.
            while (true) {
                // A source as long as the limit allows is a long walk: it stops when the run does.
                try self.io.checkCancel();
                const token = lexer.next();
                if (token.tag == .eof) break;
                if (token.tag != .builtin or !std.mem.eql(u8, sentinel[token.loc.start..token.loc.end], "@import")) continue;
                if (lexer.next().tag != .l_paren) continue;
                const literal = lexer.next();
                if (literal.tag != .string_literal) continue;
                const spelling = try std.zig.string_literal.parseAlloc(self.a, sentinel[literal.loc.start..literal.loc.end]);
                if (lexer.next().tag != .r_paren) continue;
                // The spelling is the source's: a path it names is parsed into one inside the
                // roots before anything opens it.
                const external = for (self.options.externals.items) |name| {
                    if (std.mem.eql(u8, name, spelling)) break true;
                } else false;
                const target = if (external) try self.externalInput(spelling) else target: {
                    const target_path = (try aegis.input.Untrusted(Spelling).init(.{ .from = cursor, .text = spelling }).parse(self, Loader.importPath)) orelse continue;
                    break :target try self.load(target_path, false);
                };
                var duplicate = false;
                for (self.mappings.items) |m| if (m.from == from and std.mem.eql(u8, m.spelling, spelling)) {
                    duplicate = true;
                    break;
                };
                if (!duplicate) try self.mappings.append(self.a, .{ .from = from, .spelling = spelling, .target = target });
            }
        }
    }

    /// An `@import` a loaded file spells, and the file it is written in.
    const Spelling = struct { from: usize, text: []const u8 };

    /// The file an import names: std's or a module's root by its name, or a relative path,
    /// resolved against the importing file's directory, inside the roots as Zig requires of a
    /// module's imports; null for a name that is no file of the run.
    fn importPath(self: *Loader, spelling: Spelling) error{ OutOfMemory, ImportOutsideRoots }!?[]const u8 {
        if (std.mem.eql(u8, spelling.text, "std")) {
            const lib = self.options.zig_lib_path orelse return null;
            return try std.Io.Dir.path.join(self.a, &.{ lib, "std", "std.zig" });
        }
        for (self.options.modules.items) |module| if (std.mem.eql(u8, spelling.text, module.name)) return module.path;
        // A relative path names a Zig file or a ZON one (`@import("data.zon")`), read as ZON.
        if (!std.mem.endsWith(u8, spelling.text, ".zig") and !std.mem.endsWith(u8, spelling.text, ".zon")) return null;
        if (spelling.from >= self.canonical_paths.items.len) return null;
        const path = try std.Io.Dir.path.resolveAlloc(self.a, &.{ std.Io.Dir.path.dirname(self.canonical_paths.items[spelling.from]) orelse ".", spelling.text });
        for (self.roots.items) |root| if (within(root, path)) return path;
        return error.ImportOutsideRoots;
    }
};

/// A package as its `build.zig.zon` names it: `.name` and `.fingerprint`, each where written.
const Manifest = struct {
    name: []const u8 = "",
    fingerprint: ?u64 = null,

    fn parse(a: std.mem.Allocator, bytes: [:0]const u8) !Manifest {
        var tree = try std.zig.Ast.parse(a, bytes, .{ .mode = .zon });
        defer tree.deinit(a);
        var result: Manifest = .{};
        if (tree.errors.len != 0) return result;
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const root = tree.fullStructInit(&buffer, tree.rootDecls()[0]) orelse return result;
        for (root.ast.fields) |field| {
            const name_token = tree.firstToken(field) - 2;
            const key = tree.tokenSlice(name_token);
            const value = tree.tokenSlice(tree.nodeMainToken(field));
            if (std.mem.eql(u8, key, "name")) {
                result.name = try a.dupe(u8, switch (tree.nodeTag(field)) {
                    .enum_literal => value,
                    .string_literal => std.mem.trim(u8, value, "\""),
                    else => continue,
                });
            } else if (std.mem.eql(u8, key, "fingerprint") and tree.nodeTag(field) == .number_literal) {
                result.fingerprint = std.fmt.parseInt(u64, value, 0) catch null;
            }
        }
        return result;
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
    fix: bool = false,
    escapes_before: ?[]const u8 = null,
    zig_lib_path: ?[]const u8 = null,
    module: []const []const u8 = &.{},
    exported: []const []const u8 = &.{},
    external: []const []const u8 = &.{},
    root: []const []const u8 = &.{},
    package: []const []const u8 = &.{},
    files_from: []const []const u8 = &.{},
    input_directory: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{
        .name = "glint",
        .version = release.version,
        .about = "A linter for Zig on Zig's own parser and semantic form",
        .description = "Explicit files only: no path patterns, no build.zig execution. The rules start from Z003 and Z013, or from --only, --reviewed or --config (--only beside --config runs only its rules under the configuration's policy); --report, --gate and --disable then set a rule's level. The rules a package the files import declares in its lint_rules join the run, each on by its own default. A caller that wants the run's record names it first: --result FILE --run-id ID. Suppress one site with // glint-ignore: Z013 -- written reason. Exit: 0 complete and clean; 1 findings; 2 input, tool or incomplete analysis.",
        .options = .{
            .files = .{ .positional = true, .value_name = "FILE", .hint = .file, .help = "A file to check" },
            .only = .{ .value_name = "ID", .section = "Rules", .help = "Check only this rule, repeated, at report level" },
            .reviewed = .{ .negatable = false, .section = "Rules", .help = "Every retained rule, at report level" },
            .config = .{ .value_name = "FILE", .hint = .file, .section = "Rules", .help = "A JSON policy: its profile, rule levels and code options; beside --only, its options alone" },
            .report = .{ .value_name = "ID", .section = "Rules", .help = "Report this rule, repeated" },
            .gate = .{ .value_name = "ID", .section = "Rules", .help = "Gate on this rule, repeated: a finding fails the run" },
            .disable = .{ .value_name = "ID", .section = "Rules", .help = "Leave this rule out, repeated" },
            .format = .{ .help = "How the report is written" },
            .max_line_length = .{ .value_name = "N", .help = "The line length Z024's readability report allows, in bytes; 100 by default" },
            .max_function_lines = .{ .value_name = "N", .help = "The lines P003 allows a function; 120 by default" },
            .fact_budget = .{ .value_name = "N", .help = "How many facts a file's analysis may resolve; 100000 by default" },
            .strict_suppressions = .{ .negatable = false, .help = "A suppression that suppresses nothing makes the run incomplete" },
            .metrics = .{ .negatable = false, .help = "Count each file's functions and assertion calls into the report" },
            .fix = .{ .negatable = false, .help = "Apply each finding's deterministic fix to its file (the aegis pack's), and remove escapes that cover nothing; the report is the run before them" },
            .escapes_before = .{ .value_name = "FILE", .hint = .file, .help = "The escapes a run before reported (its text report, or preflight's escapes.txt): --fix names an escape in the older form, at that place with those words, with only the rules listed for it there that find something now, and leaves one not listed to its owner; never with --only" },
            .zig_lib_path = .{ .value_name = "DIR", .hint = .directory, .section = "Inputs", .help = "Zig's library, for std's imports" },
            .module = .{ .value_name = "NAME=FILE", .section = "Inputs", .help = "A module the files import by name, and its root file, repeated" },
            .exported = .{ .value_name = "FILE", .hint = .file, .section = "Inputs", .help = "The root of a module the package exports, repeated: Z012 reads the public surface these reach, and none without one" },
            .external = .{ .value_name = "NAME", .section = "Inputs", .help = "A module whose bytes a build step makes (translate-c, a Run step's output), repeated: an import of it is read as nothing glint has, never linted" },
            .root = .{ .value_name = "DIR", .hint = .directory, .section = "Inputs", .help = "A directory imports may read files from, repeated" },
            .package = .{ .value_name = "NAME=DIR", .section = "Inputs", .help = "The package whose files a directory holds, repeated" },
            .files_from = .{ .value_name = "FILE", .hint = .file, .section = "Inputs", .help = "A file naming files to check under this directory, one a line, repeated" },
            .input_directory = .{ .value_name = "DIR", .hint = .directory, .hidden = true, .help = "A directory the caller's build reads; never a selection of files" },
        },
        // A run of some rules sees only what they cover: it never names an older escape.
        .conflicts = &.{ &.{ .only, .reviewed }, &.{ .only, .escapes_before } },
    };
};

/// What the arguments ask: the profile chosen, the rules named (resolved by `resolve` once the
/// packages' rules are read), the code options and the inputs.
fn options(a: std.mem.Allocator, io: std.Io, arguments: Arguments, problems: *std.Io.Writer) !Options {
    var result: Options = .{ .format = arguments.format, .zig_lib_path = arguments.zig_lib_path };
    if (arguments.config) |path| {
        const bytes = try aegis.own.readFile(io, std.Io.Dir.cwd(), path, a, .fromRaw(4 * 1024 * 1024));
        // A configuration file is the checked repository's content: input until parsed.
        const configured = try aegis.input.Untrusted([]const u8).init(bytes).parse(a, configure);
        if (configured.refused_profile) |name| {
            try problems.writeAll("glint: ");
            try refuseProfile(problems, name);
            try problems.writeByte('\n');
            try problems.flush();
            return error.UnknownProfile;
        }
        result.config = configured.config;
        // Its seams and test inputs name paths from its own directory.
        const real = try std.Io.Dir.cwd().realPathFileAlloc(io, path, a);
        result.config.paths_from = std.Io.Dir.path.dirname(real) orelse ".";
        // Relative input names are from the working directory.
        result.config.names_from = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
        result.settings = configured.settings;
        result.package_defaults = configured.package_defaults;
    } else if (arguments.reviewed) {
        result.config = Rule.Config.reviewed();
    }
    // --only names the rules that run; a configuration beside it lends only its options (the
    // declarations a project disallows, its peer writers, its limits), never its rules.
    result.only = arguments.only;
    result.levels = .{ .{ arguments.report, .report }, .{ arguments.gate, .gate }, .{ arguments.disable, .off } };
    if (arguments.max_line_length) |n| result.config.max_line_length = n;
    if (arguments.max_function_lines) |n| result.config.max_function_lines = n;
    if (arguments.fact_budget) |n| result.config.fact_budget = n;
    if (arguments.strict_suppressions) result.config.strict_suppressions = true;
    if (arguments.metrics) result.config.metrics = true;
    result.fix = arguments.fix;
    if (arguments.escapes_before) |path| {
        const bytes = try aegis.own.readFile(io, std.Io.Dir.cwd(), path, a, .fromRaw(16 * 1024 * 1024));
        // A record is a file another run wrote, which the fix reads as input until parsed.
        result.escapes_before = try aegis.input.Untrusted([]const u8).init(bytes).parse(a, Fix.escapeRecord);
    }
    try result.roots.appendSlice(a, arguments.root);
    for (arguments.module) |mapping| try result.modules.append(a, named(mapping) orelse return error.InvalidModule);
    try result.exported.appendSlice(a, arguments.exported);
    try result.externals.appendSlice(a, arguments.external);
    for (arguments.package) |mapping| try result.packages.append(a, named(mapping) orelse return error.InvalidPackage);
    try result.files.appendSlice(a, arguments.files);
    for (arguments.files_from) |from| {
        const read = try aegis.own.readFile(io, std.Io.Dir.cwd(), from, a, .fromRaw(4 * 1024 * 1024));
        // A list is a file, which may be what a repository holds: its paths are parsed into
        // ones under the directory glint runs in before any is opened.
        try result.files.appendSlice(a, try aegis.input.Untrusted([]const u8).init(read).parse(a, fileList));
    }
    return result;
}

/// The first rule `result` names that glint and `definitions` do not have. Where `own_form`,
/// only a name of glint's own form (Z, P, D), which no package may declare: it is unknown before
/// the project is read, where any other waits for the packages' rules.
fn unknownRule(result: *const Options, definitions: []const Rule.Definition, own_form: bool) ?[]const u8 {
    for (result.settings) |setting| if (unknown(setting.id, definitions, own_form)) return setting.id;
    for (result.only) |id| if (unknown(id, definitions, own_form)) return id;
    for (result.levels) |level| for (level[0]) |id| if (unknown(id, definitions, own_form)) return id;
    // A seam names rules the run has.
    if (!own_form) for (result.config.seams) |seam| for (seam.rules) |name| if (unknown(name, definitions, false)) return name;
    return null;
}

fn unknown(name: []const u8, definitions: []const Rule.Definition, own_form: bool) bool {
    if (own_form and (name.len == 0 or std.mem.findScalar(u8, "ZPD", name[0]) == null)) return false;
    return Rule.parseConfigured(name, definitions) == null;
}

/// What a configuration naming a profile glint does not have is told: 0.7's `aegis` and `family`
/// with where their rules are now.
fn refuseProfile(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    if (std.mem.eql(u8, name, "aegis") or std.mem.eql(u8, name, "family"))
        return w.print("profile `{s}` was removed in glint 0.8: aegis's rules are its own `lint_rules`, on wherever the program reaches aegis, and glint's are in `core` and `reviewed`; name one of those", .{name});
    try w.print("profile `{s}` is not one glint has: `core`, `none` or `reviewed`", .{name});
}

/// Refuses a run that names a rule it does not have (`unknownRule`), saying which and, where
/// glint 0.8 removed it, what to write instead (`Rule.Removed`).
fn refuseUnknown(result: *const Options, definitions: []const Rule.Definition, own_form: bool, problems: *std.Io.Writer) !void {
    const name = unknownRule(result, definitions, own_form) orelse return;
    try problems.writeAll("glint: ");
    try Rule.Removed.refuse(problems, name);
    try problems.writeByte('\n');
    try problems.flush();
    return error.UnknownRule;
}

/// The rules `options` asked by name, now that `definitions` holds every rule of the run (the
/// caller's and the packages'): each package rule that is on unasked and nothing set, the configuration's settings, `--only` (which starts from none), then each
/// level's names. A name no rule has is `UnknownRule`.
fn resolve(a: std.mem.Allocator, result: *Options, definitions: []const Rule.Definition) !void {
    result.config.package_defaults = result.package_defaults;
    for (result.settings, 0..) |setting, i| {
        for (result.settings[0..i]) |earlier| if (std.mem.eql(u8, setting.id, earlier.id)) return error.InvalidSelection;
        try select(a, &result.config, Rule.parseConfigured(setting.id, definitions) orelse return error.UnknownRule, setting.level);
    }
    if (result.only.len != 0) {
        result.config.enabled = Rule.Config.none().enabled;
        result.config.selections = &.{};
        result.config.package_defaults = false;
        for (result.only) |id| try select(a, &result.config, Rule.parseConfigured(id, definitions) orelse return error.UnknownRule, .report);
    }
    for (result.levels) |level| for (level[0]) |id| try select(a, &result.config, Rule.parseConfigured(id, definitions) orelse return error.UnknownRule, level[1]);
    // A seam names rules the run has.
    for (result.config.seams) |seam| for (seam.rules) |name| if (Rule.parseConfigured(name, definitions) == null) return error.UnknownRule;
    try result.config.validate();
}

/// The files a `--files-from` list names, one a line, blank lines aside: each a relative path
/// with no `..` part, so a file under the directory glint runs in.
fn fileList(a: std.mem.Allocator, bytes: []const u8) error{ OutOfMemory, FileListPathOutside }![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, "\r");
        if (path.len == 0) continue;
        if (std.Io.Dir.path.isAbsolute(path)) return error.FileListPathOutside;
        var parts = std.mem.tokenizeAny(u8, path, "/\\");
        while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.FileListPathOutside;
        try paths.append(a, path);
    }
    return paths.items;
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
    return executeConfigured(gpa, io, args, writer, problems, &.{});
}
/// Standalone CLI for compiled project rules. Same completion and output contract.
pub fn executeConfigured(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer, problems: *std.Io.Writer, project_rules: []const RuleContext.Rule) !u8 {
    return executeWith(gpa, io, args, writer, problems, project_rules, null);
}
/// Runs glint on `args` as `execute` does, each file read through `store`: runs sharing it
/// read a file they share once, std's among them (glint's soundness suite, a run per case).
pub fn executeStored(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer, problems: *std.Io.Writer, store: *Project.Store) !u8 {
    return executeWith(gpa, io, args, writer, problems, &.{}, store);
}
fn executeWith(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer, problems: *std.Io.Writer, project_rules: []const RuleContext.Rule, store: ?*Project.Store) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostic: ensign.Diagnostic = .{};
    const line = if (args.len == 0) args else args[1..];
    const request = switch (ensign.parse(Request, a, line, .{ .diagnostic = &diagnostic }) catch |err| return refused(err, diagnostic, problems)) {
        .parsed => |parsed| parsed,
        // `Request` leaves `--help` to the arguments and has no version, and only
        // `parseArgs` answers a completion.
        .help, .version, .complete => unreachable,
    };
    const requested = try Result.request(request.result, request.run_id);
    var record: Result.Record = .{ .run_id = if (requested) |req| req.run_id else "", .version = 1, .completed = false, .outcome = .running, .sources = 0, .findings = 0, .suppressed = 0, .output_bytes = 0, .output_sha256 = "" };
    try Result.publish(a, io, requested, record);
    const status = executeInner(gpa, a, io, request.arguments, writer, problems, &record, project_rules, store) catch |err| {
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

fn executeInner(gpa: std.mem.Allocator, result_a: std.mem.Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer, problems: *std.Io.Writer, record: *Result.Record, project_rules: []const RuleContext.Rule, store: ?*Project.Store) !u8 {
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
        // Only `parseArgs` answers a completion; these are the arguments themselves, and an
        // outcome no parse of them gives is a refusal, not a state the program cannot reach.
        .complete => return error.InvalidArguments,
    };
    var configured = try options(a, io, arguments, problems);
    try refuseUnknown(&configured, definitions, true, problems);
    if (configured.files.items.len == 0) return error.MissingSource;
    record.outcome = .input_failure;
    var loader: Loader = .{ .a = a, .io = io, .options = &configured };
    for (configured.packages.items) |package| try loader.packages.append(a, .{ .name = package.name, .path = try std.Io.Dir.cwd().realPathFileAlloc(io, package.path, a) });
    for (configured.roots.items) |root| try loader.roots.append(a, try std.Io.Dir.cwd().realPathFileAlloc(io, root, a));
    for (configured.files.items) |path| {
        const position = try loader.load(path, true);
        const canonical = loader.canonical_paths.items[position];
        try loader.roots.append(a, std.Io.Dir.path.dirname(canonical) orelse canonical);
    }
    if (configured.zig_lib_path) |lib| try loader.roots.append(a, try std.Io.Dir.cwd().realPathFileAlloc(io, lib, a));
    for (configured.modules.items) |module| {
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, module.path, a);
        try loader.roots.append(a, std.Io.Dir.path.dirname(canonical) orelse canonical);
    }
    record.outcome = .traversal_failure;
    try loader.imports();
    for (configured.exported.items) |root| {
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, root, a);
        if (loader.paths.get(canonical)) |position| loader.inputs.items[position].exported = true;
    }
    record.outcome = .tool_failure;
    var project = try Project.init(gpa, loader.inputs.items, loader.mappings.items, .{ .io = io, .store = store });
    defer project.deinit();
    // The rules the project's packages declare, then every name asked, now resolvable.
    const declared = try Runner.packageRules(a, &project);
    const all = try std.mem.concat(a, Rule.Definition, &.{ definitions, declared });
    record.outcome = .argument_failure;
    try refuseUnknown(&configured, all, false, problems);
    try resolve(a, &configured, all);
    record.outcome = .tool_failure;
    const config = configured.config;
    var report = try Runner.runConfigured(gpa, &project, config, .{ .project_rules = project_rules, .io = io });
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
    if (configured.fix) {
        var made: usize = 0;
        const changed = try Fix.apply(a, &project, &report, .{ .escapes_before = configured.escapes_before });
        for (changed) |file| {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = project.at(file.file).input.name, .data = file.bytes });
            made += file.sites;
        }
        try problems.print("glint: fixed {d} sites in {d} files\n", .{ made, changed.len });
        try problems.flush();
    }
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

/// `options` in a test, its problems written nowhere.
fn testOptions(a: std.mem.Allocator, arguments: Arguments) !Options {
    var buffer: [256]u8 = undefined;
    var problems: std.Io.Writer = .fixed(&buffer);
    return options(a, std.testing.io, arguments, &problems);
}

test "a configuration naming 0.7's aegis or family profile is refused with where its rules are now" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("aegis", (try configure(arena.allocator(), "{\"profile\": \"aegis\"}")).refused_profile.?);
    try std.testing.expectEqual(@as(?[]const u8, null), (try configure(arena.allocator(), "{\"profile\": \"reviewed\"}")).refused_profile);
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try refuseProfile(&w, "family");
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "profile `family` was removed in glint 0.8"));
    w.end = 0;
    try refuseProfile(&w, "strict");
    try std.testing.expectEqualStrings("profile `strict` is not one glint has: `core`, `none` or `reviewed`", w.buffered());
}

test "fuzz: the configuration JSON" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [4096]u8 = undefined;
            const bytes = buffer[0..smith.slice(&buffer)];
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            // A document refused for its JSON is the answer: the CLI says so. Its rule names are
            // resolved later, against the run's rules (`resolve`).
            _ = configure(arena.allocator(), bytes) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return,
            };
        }
    };
    try std.testing.fuzz({}, Target.one, .{ .corpus = &.{
        "{\"profile\": \"reviewed\", \"rules\": [{\"id\": \"Z026\", \"level\": \"gate\"}]}",
        "{\"profile\": \"reviewed\", \"max_line_length\": 120, \"disallowed\": [{\"source\": \"std\", \"declaration\": \"debug.print\", \"reason\": \"r\", \"replacement\": \"x\"}]}",
        "{\"function_exceptions\": [{\"function\": \"f\", \"lines\": 200, \"reason\": \"r\"}]}",
        "{\"profile\": \"reviewed\", \"max_parameters\": 4, \"max_nesting\": 3, \"max_stack_array\": 4096, \"rules\": [{\"id\": \"P013\", \"level\": \"report\"}]}",
        "{",
    } });
}

test "CLI invalid selections and unknown formats fail" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // A name of glint's own form is known or not before the project is read; any other waits
    // for the packages' rules.
    const own = try testOptions(arena.allocator(), .{ .only = &.{"Z008"} });
    try std.testing.expectEqualStrings("Z008", unknownRule(&own, &.{}, true).?);
    var asked = try testOptions(arena.allocator(), .{ .only = &.{"X008"} });
    try std.testing.expectEqual(@as(?[]const u8, null), unknownRule(&asked, &.{}, true));
    try std.testing.expectEqualStrings("X008", unknownRule(&asked, &.{}, false).?);
    try std.testing.expectError(error.UnknownRule, resolve(arena.allocator(), &asked, &.{}));
    try std.testing.expectError(error.InvalidValue, ensign.parse(Arguments, arena.allocator(), &.{ "--format", "other" }, .{}));
    // A run of some rules never names an older escape from a record.
    try std.testing.expectError(error.Conflict, ensign.parse(Arguments, arena.allocator(), &.{ "--only", "A009", "--escapes-before", "escapes.txt", "--fix" }, .{}));
    try std.testing.expect(within("/root", "/root/src/x.zig"));
    try std.testing.expect(!within("/root", "/root-copy/x.zig"));
}

test "a configuration's limits reach the rules that read them: P013's parameters and nesting, Z038's array bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const configured = try configure(arena.allocator(), "{\"profile\": \"reviewed\", \"max_parameters\": 4, \"max_nesting\": 3, \"max_stack_array\": 4096}");
    try std.testing.expectEqual(@as(u32, 4), configured.config.max_parameters);
    try std.testing.expectEqual(@as(u32, 3), configured.config.max_nesting);
    try std.testing.expectEqual(@as(u64, 4096), configured.config.max_stack_array);
    // The opt-in rules stay off under the reviewed profile until a setting names them.
    try std.testing.expect(configured.config.has(.Z035) and !configured.config.has(.P013));
}

/// Strict JSON policy, containing code options only. Callers own file selection.
pub const Configuration = struct {
    /// `core`, `none` or `reviewed`; 0.7's `aegis` and `family` are refused with what to
    /// write instead.
    profile: []const u8 = "core",
    rules: []const Setting = &.{},
    max_line_length: u32 = 100,
    max_function_lines: u32 = 120,
    max_parameters: u32 = 7,
    max_nesting: u32 = 5,
    max_stack_array: u64 = 64 * 1024,
    function_exceptions: []const Rule.Config.FunctionException = &.{},
    disallowed: []const Rule.Config.Disallowed = &.{},
    strict_suppressions: bool = false,
    metrics: bool = false,
    fact_budget: usize = 100_000,
    seams: []const Rule.Config.Seam = &.{},
    test_inputs: []const Rule.Config.TestInput = &.{},
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
const ConfigureError = std.json.ParseError(std.json.Scanner) || error{InvalidSelection};
const Configured = struct { config: Rule.Config, package_defaults: bool, settings: []const Configuration.Setting, refused_profile: ?[]const u8 = null };
/// A configuration's profile and code options; its rule settings are named, for `resolve`.
fn configure(a: std.mem.Allocator, bytes: []const u8) ConfigureError!Configured {
    const document = try std.json.parseFromSliceLeaky(Configuration, a, bytes, .{});
    const profile = std.meta.stringToEnum(enum { core, none, reviewed }, document.profile) orelse
        return .{ .config = .{}, .package_defaults = false, .settings = &.{}, .refused_profile = document.profile };
    var config: Rule.Config = switch (profile) {
        .core => .{},
        .none => Rule.Config.none(),
        .reviewed => Rule.Config.reviewed(),
    };
    config.max_line_length = document.max_line_length;
    config.max_function_lines = document.max_function_lines;
    config.max_parameters = document.max_parameters;
    config.max_nesting = document.max_nesting;
    config.max_stack_array = document.max_stack_array;
    config.function_exceptions = document.function_exceptions;
    config.disallowed = document.disallowed;
    config.strict_suppressions = document.strict_suppressions;
    config.metrics = document.metrics;
    config.fact_budget = document.fact_budget;
    config.seams = document.seams;
    config.test_inputs = document.test_inputs;
    try config.validate();
    return .{ .config = config, .package_defaults = profile != .none, .settings = document.rules };
}

test "the packages' rules on by default run unless a profile of none or --only says otherwise, and a package rule's name resolves once the packages' rules are read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const declared = [_]Rule.Definition{
        .{ .id = @fromBackingInt(2000), .name = "X001", .group = .family_policy, .purpose = "p", .declared = .{ .package = "pkg", .kind = .ban, .reads = .replaces, .default = true } },
        .{ .id = @fromBackingInt(2001), .name = "X002", .group = .family_policy, .purpose = "q", .declared = .{ .package = "pkg", .kind = .ban, .reads = .replaces, .default = false } },
    };
    var plain = try testOptions(a, .{});
    try resolve(a, &plain, &declared);
    // The run selects the defaults (Runner); the configuration says it takes them.
    try std.testing.expect(plain.config.package_defaults);
    var only = try testOptions(a, .{ .only = &.{"X002"} });
    try resolve(a, &only, &declared);
    try std.testing.expect(!only.config.package_defaults);
    try std.testing.expectEqual(Rule.Config.Level.report, only.config.level(declared[1].id));
}
