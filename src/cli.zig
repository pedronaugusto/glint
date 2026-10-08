//! Filesystem front end for explicit inputs. No globs, build execution or hidden cache.
const std = @import("std");
const glint = @import("glint");
const Result = @import("Result.zig");
const Cli = @This();

const Module = struct { name: []const u8, path: []const u8 };
const Options = struct {
    config: glint.Config = .{},
    format: glint.Report.Format = .text,
    files: std.ArrayList([]const u8) = .empty,
    modules: std.ArrayList(Module) = .empty,
    roots: std.ArrayList([]const u8) = .empty,
    zig_lib_path: ?[]const u8 = null,
    help: bool = false,
};

const Loader = struct {
    a: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    inputs: std.ArrayList(glint.Project.Input) = .empty,
    mappings: std.ArrayList(glint.Project.Import) = .empty,
    paths: std.StringHashMapUnmanaged(glint.Project.FileId) = .empty,
    canonical_paths: std.ArrayList([]const u8) = .empty,
    roots: std.ArrayList([]const u8) = .empty,
    bytes: usize = 0,

    fn load(self: *Loader, path: []const u8, selected: bool) !glint.Project.FileId {
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
        const bytes = try std.Io.Dir.cwd().readFileAllocOptions(self.io, canonical, self.a, .limited(16 * 1024 * 1024), .@"1", 0);
        self.bytes += bytes.len;
        if (self.bytes > 128 * 1024 * 1024) return error.SourceBudgetExceeded;
        const id: glint.Project.FileId = glint.Project.FileId.fromRaw(@intCast(self.inputs.items.len)); // safe: the loader bounds source count to 4096 before creating u32 identities.
        const basename = std.fs.path.basename(path);
        const stem = if (std.mem.endsWith(u8, basename, ".zig")) basename[0 .. basename.len - 4] else basename;
        try self.inputs.append(self.a, .{ .name = path, .stem = stem, .bytes = bytes, .selected = selected });
        try self.canonical_paths.append(self.a, canonical);
        try self.paths.put(self.a, canonical, id);
        return id;
    }

    fn imports(self: *Loader) !void {
        var cursor: usize = 0;
        while (cursor < self.inputs.items.len) : (cursor += 1) {
            const from: glint.Project.FileId = glint.Project.FileId.fromRaw(@intCast(cursor)); // safe: the loader bounds source count to 4096 before creating u32 identities.
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
            const path = try std.fs.path.join(self.a, &.{ lib, "std", "std.zig" });
            return path;
        }
        for (self.options.modules.items) |module| if (std.mem.eql(u8, spelling, module.name)) return module.path;
        if (!std.mem.endsWith(u8, spelling, ".zig")) return null;
        const path = try std.fs.path.join(self.a, &.{ std.fs.path.dirname(self.canonical_paths.items[from]) orelse ".", spelling });
        return path;
    }
};

fn within(root: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, root, path) or (root.len == 1 and std.fs.path.isSep(root[0]) and std.fs.path.isAbsolute(path)) or (std.mem.startsWith(u8, path, root) and path.len > root.len and std.fs.path.isSep(path[root.len]));
}

fn value(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingArgument;
    return args[index.*];
}

fn options(a: std.mem.Allocator, io: std.Io, args: []const []const u8) !Options {
    return optionsConfigured(a, io, args, &.{});
}
fn optionsConfigured(a: std.mem.Allocator, io: std.Io, args: []const []const u8, definitions: []const glint.RuleDefinition) !Options {
    var result: Options = .{};
    var selected = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            result.help = true;
        } else if (std.mem.eql(u8, arg, "--format")) {
            result.format = std.meta.stringToEnum(glint.Report.Format, try value(args, &i)) orelse return error.UnknownFormat;
        } else if (std.mem.eql(u8, arg, "--only")) {
            if (!selected) {
                result.config = glint.Config.none();
                selected = true;
            }
            const rule = glint.parseRule(try value(args, &i), definitions) orelse return error.UnknownRule;
            try select(a, &result.config, rule, .report);
        } else if (std.mem.eql(u8, arg, "--reviewed")) {
            result.config = glint.Config.reviewed();
            selected = false;
        } else if (std.mem.eql(u8, arg, "--enable") or std.mem.eql(u8, arg, "--disable")) {
            const rule = glint.parseRule(try value(args, &i), definitions) orelse return error.UnknownRule;
            try select(a, &result.config, rule, if (std.mem.eql(u8, arg, "--enable")) .report else .off);
        } else if (std.mem.eql(u8, arg, "--family")) {
            result.config = glint.Config.family();
            selected = false;
        } else if (std.mem.eql(u8, arg, "--gate") or std.mem.eql(u8, arg, "--report")) {
            const rule = glint.parseRule(try value(args, &i), definitions) orelse return error.UnknownRule;
            try select(a, &result.config, rule, if (std.mem.eql(u8, arg, "--gate")) .gate else .report);
        } else if (std.mem.eql(u8, arg, "--config")) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, try value(args, &i), a, .limited(4 * 1024 * 1024));
            result.config = try configure(a, bytes, definitions);
            selected = false;
        } else if (std.mem.eql(u8, arg, "--max-function-lines")) {
            result.config.max_function_lines = try std.fmt.parseInt(u32, try value(args, &i), 10);
        } else if (std.mem.eql(u8, arg, "--fact-budget")) {
            result.config.fact_budget = try std.fmt.parseInt(usize, try value(args, &i), 10);
        } else if (std.mem.eql(u8, arg, "--max-line-length")) {
            result.config.max_line_length = try std.fmt.parseInt(u32, try value(args, &i), 10);
        } else if (std.mem.eql(u8, arg, "--strict-suppressions")) {
            result.config.strict_suppressions = true;
        } else if (std.mem.eql(u8, arg, "--zig-lib-path")) {
            result.zig_lib_path = try value(args, &i);
        } else if (std.mem.eql(u8, arg, "--root")) {
            try result.roots.append(a, try value(args, &i));
        } else if (std.mem.eql(u8, arg, "--module")) {
            const mapping = try value(args, &i);
            const equals = std.mem.findScalar(u8, mapping, '=') orelse return error.InvalidModule;
            if (equals == 0 or equals + 1 == mapping.len) return error.InvalidModule;
            try result.modules.append(a, .{ .name = mapping[0..equals], .path = mapping[equals + 1 ..] });
        } else if (std.mem.eql(u8, arg, "--result") or std.mem.eql(u8, arg, "--run-id")) {
            _ = try value(args, &i);
        } else if (std.mem.eql(u8, arg, "--input-directory")) {
            _ = try value(args, &i); // Caller build input only; never source selection.
        } else if (std.mem.eql(u8, arg, "--files-from")) {
            const list = try std.Io.Dir.cwd().readFileAlloc(io, try value(args, &i), a, .limited(4 * 1024 * 1024));
            var lines = std.mem.splitScalar(u8, list, '\n');
            while (lines.next()) |line| {
                const path = std.mem.trim(u8, line, "\r");
                if (path.len > 0) try result.files.append(a, path);
            }
        } else if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption else try result.files.append(a, arg);
    }
    return result;
}

pub fn execute(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer) !u8 {
    return executeConfigured(gpa, io, args, writer, &glint.AegisPack.rules);
}
/// Standalone CLI for compiled project rules. Same completion and output contract.
pub fn executeConfigured(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer, project_rules: []const glint.ProjectRule) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const requested = try Result.request(args);
    var record: Result.Record = .{ .run_id = if (requested) |req| req.run_id else "", .version = 1, .completed = false, .outcome = .running, .sources = 0, .findings = 0, .suppressed = 0, .output_bytes = 0, .output_sha256 = "" };
    try Result.publish(a, io, requested, record);
    const status = executeInner(gpa, a, io, args, writer, &record, project_rules) catch |err| {
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

fn executeInner(gpa: std.mem.Allocator, result_a: std.mem.Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer, record: *Result.Record, project_rules: []const glint.ProjectRule) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    record.outcome = .argument_failure;
    const definitions = try a.alloc(glint.RuleDefinition, project_rules.len);
    for (project_rules, 0..) |rule, i| definitions[i] = rule.definition;
    const configured = try optionsConfigured(a, io, args, definitions);
    if (configured.help) {
        record.outcome = .output_failure;
        try writer.writeAll("glint [--only ID | --reviewed | --family] [--format text|json|sarif]\n      [--config FILE] [--gate ID | --report ID] [--max-function-lines N]\n      [--zig-lib-path DIR] [--module NAME=FILE] [--root DIR]\n      [--files-from FILE] [--fact-budget N] [--strict-suppressions] [--result FILE --run-id ID] FILE...\n\nExplicit files only. No path patterns or build.zig execution.\nSuppress one site: // glint-ignore: Z013 -- written reason\nExit: 0 complete/clean; 1 findings; 2 input/tool/incomplete.\n");
        try writer.flush();
        record.outcome = .help;
        record.completed = false;
        return 0;
    }
    if (configured.files.items.len == 0) return error.MissingSource;
    record.outcome = .input_failure;
    var loader: Loader = .{ .a = a, .io = io, .options = &configured };
    for (configured.roots.items) |root| try loader.roots.append(a, try std.Io.Dir.cwd().realPathFileAlloc(io, root, a));
    for (configured.files.items) |path| {
        const id = try loader.load(path, true);
        const canonical = loader.canonical_paths.items[id.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
        try loader.roots.append(a, std.fs.path.dirname(canonical) orelse canonical);
    }
    if (configured.zig_lib_path) |lib| try loader.roots.append(a, try std.Io.Dir.cwd().realPathFileAlloc(io, lib, a));
    for (configured.modules.items) |module| {
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, module.path, a);
        try loader.roots.append(a, std.fs.path.dirname(canonical) orelse canonical);
    }
    record.outcome = .traversal_failure;
    try loader.imports();
    record.outcome = .tool_failure;
    var project = try glint.Project.init(gpa, loader.inputs.items, loader.mappings.items, .{});
    defer project.deinit();
    var report = try glint.runConfigured(gpa, &project, configured.config, .{ .project_rules = project_rules });
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

test "CLI invalid selections and unknown formats fail" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownRule, options(arena.allocator(), std.testing.io, &.{ "glint", "--only", "Z008" }));
    try std.testing.expectError(error.UnknownFormat, options(arena.allocator(), std.testing.io, &.{ "glint", "--format", "other" }));
    try std.testing.expect(within("/root", "/root/src/x.zig"));
    try std.testing.expect(!within("/root", "/root-copy/x.zig"));
}

/// Strict JSON policy, containing code options only. Callers own file selection.
pub const Configuration = struct {
    profile: enum { core, none, reviewed, family } = .core,
    rules: []const Setting = &.{},
    max_line_length: u32 = 100,
    max_function_lines: u32 = 120,
    cast_scope: @FieldType(glint.Config, "cast_scope") = .all,
    casts: @FieldType(glint.Config, "casts") = .all,
    function_exceptions: []const glint.Config.FunctionException = &.{},
    disallowed: []const glint.Config.Disallowed = &.{},
    strict_suppressions: bool = false,
    fact_budget: usize = 100_000,
    pub const Setting = struct { id: []const u8, level: glint.Config.Level };
};
fn select(a: std.mem.Allocator, config: *glint.Config, id: glint.Rule, level: glint.Config.Level) !void {
    const selections = try a.alloc(glint.Config.Selection, config.selections.len + 1);
    @memcpy(selections[0..config.selections.len], config.selections);
    for (selections[0..config.selections.len], 0..) |selection, i| if (selection.rule == id) {
        selections[i].level = level;
        config.selections = selections[0..config.selections.len];
        return;
    };
    selections[config.selections.len] = .{ .rule = id, .level = level };
    config.selections = selections;
}
fn configure(a: std.mem.Allocator, bytes: []const u8, definitions: []const glint.RuleDefinition) !glint.Config {
    const document = try std.json.parseFromSliceLeaky(Configuration, a, bytes, .{});
    var config: glint.Config = switch (document.profile) {
        .core => .{},
        .none => glint.Config.none(),
        .reviewed => glint.Config.reviewed(),
        .family => glint.Config.family(),
    };
    config.max_line_length = document.max_line_length;
    config.max_function_lines = document.max_function_lines;
    config.cast_scope = document.cast_scope;
    config.casts = document.casts;
    config.function_exceptions = document.function_exceptions;
    config.disallowed = document.disallowed;
    config.strict_suppressions = document.strict_suppressions;
    config.fact_budget = document.fact_budget;
    for (document.rules, 0..) |setting, i| {
        for (document.rules[0..i]) |earlier| if (std.mem.eql(u8, setting.id, earlier.id)) return error.InvalidSelection;
        const id = glint.parseRule(setting.id, definitions) orelse return error.UnknownRule;
        try select(a, &config, id, setting.level);
    }
    try config.validate();
    return config;
}
