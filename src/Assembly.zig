//! A project file's files and how each import in them resolves (contract v1, docs/design.md "The
//! program contract"): the selected files, the build scripts, and every file their imports reach,
//! each import bound as the build's own modules bind it, so a name means what the compiler takes
//! it to mean. The caller hands the build graph; this reads it. Moved from preflight's
//! checks/glint/assembly.zig with the contract, which ran it against glint's library.
const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");
const Project = @import("Project.zig");
const Token = @import("Token.zig");
const Contract = @import("Contract.zig");

const ProjectFile = Contract.ProjectFile;

/// Files and bytes one project holds: glint's own bounds.
const max_files: usize = 4096;
const max_bytes: usize = 128 * 1024 * 1024;

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error || std.Io.Cancelable || error{ ProjectBudgetExceeded, InputNotFound, InputNotCompiled, InputUnreadable };

/// The project's inputs and import edges, ready for `Project.init`, the selected files first in
/// the project file's order.
pub const Assembled = struct {
    inputs: []const Project.Input,
    imports: []const Project.Import,
};

/// A path in one lexical form: `/` separators, no `.` or `..` components where they can be
/// removed.
pub fn normalize(a: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    const resolved = try std.Io.Dir.path.resolveAlloc(a, &.{path});
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, resolved, '\\', '/');
    return resolved;
}

/// Whether an import names a file by its path from the importing one, as Zig reads it: a Zig
/// file, or a ZON one (`@import("build.zig.zon")`), never a module.
fn relativeFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon");
}

fn join(a: std.mem.Allocator, directory: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    return normalize(a, try std.Io.Dir.path.join(a, &.{ directory, name }));
}

/// The build's modules as an import in one of its files reads them: which modules compile each
/// file their roots reach through relative imports, and what a name imported in a file binds to
/// there. The assembly reads the package's files through it, and the surface follows a facade
/// into the package's own modules through it: one reading of the build's bindings for both.
pub const ModuleMap = struct {
    modules: []const ProjectFile.Module,
    /// The modules whose sources reach a file through relative imports, by path.
    modules_of: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,

    /// What the modules of one compilation that compile a file bind a name to: nothing, or each
    /// root file (one, or several where those modules bind it apart). A module whose root the
    /// project file holds no bytes of is `externalPath`'s: bodiless, read as an external module.
    pub const Bound = union(enum) { unbound, paths: []const []const u8 };
    pub const In = enum { program, build };

    /// The map of `modules` over the files `files` holds: `files.read(path)` gives a file's text
    /// by its path or null where there is none, and `files.importsOf(path, text)` the names it
    /// imports.
    pub fn init(a: std.mem.Allocator, modules: []const ProjectFile.Module, files: anytype) !ModuleMap {
        var map: ModuleMap = .{ .modules = modules };
        for (modules, 0..) |module, which| {
            const root = module.root orelse continue;
            var pending: std.ArrayList([]const u8) = .empty;
            const start = try normalize(a, root);
            if (try map.mark(a, start, @intCast(which))) try pending.append(a, start);
            while (pending.pop()) |path| {
                const bytes = (try files.read(path)) orelse continue;
                for (try files.importsOf(path, bytes)) |name| {
                    if (!relativeFile(name)) continue;
                    const target = try join(a, std.Io.Dir.path.dirname(path) orelse "", name);
                    if (try map.mark(a, target, @intCast(which))) try pending.append(a, target);
                }
            }
        }
        return map;
    }

    fn mark(map: *ModuleMap, a: std.mem.Allocator, path: []const u8, module: u32) !bool {
        const entry = try map.modules_of.getOrPut(a, path);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        for (entry.value_ptr.items) |earlier| if (earlier == module) return false;
        try entry.value_ptr.append(a, module);
        return true;
    }

    /// Whether a module of the build compiles the file at `path`.
    pub fn compiles(map: ModuleMap, path: []const u8) bool {
        return map.modules_of.contains(path);
    }

    /// The modules that compile the file at `path`, by index in `modules`.
    pub fn modulesOf(map: ModuleMap, path: []const u8) []const u32 {
        return if (map.modules_of.get(path)) |modules| modules.items else &.{};
    }

    /// What the modules of one compilation that compile `from` bind `name` to.
    pub fn bound(map: ModuleMap, a: std.mem.Allocator, from: []const u8, name: []const u8, in: In) !Bound {
        var found: std.ArrayList([]const u8) = .empty;
        for (map.modulesOf(from)) |which| {
            if (map.modules[which].script != (in == .build)) continue;
            for (map.modules[which].imports) |binding| {
                if (!std.mem.eql(u8, binding.name, name)) continue;
                if (binding.module >= map.modules.len) continue;
                const path = if (map.modules[binding.module].root) |root| try normalize(a, root) else try externalPath(a, binding.name);
                for (found.items) |earlier| {
                    if (std.mem.eql(u8, earlier, path)) break;
                } else try found.append(a, path);
            }
        }
        return if (found.items.len == 0) .unbound else .{ .paths = found.items };
    }
};

/// The name a module whose bytes exist only after a build step runs is given, as glint's command
/// line spells one (`--external NAME`): no file, a bodiless input read as external.
fn externalPath(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return a.print("<external {s}>", .{name});
}

/// What `bytes` imports, each name once, in the order written. Text whose literals do not scan
/// imports nothing here: the project's own parse of it reports the file as unusable.
pub fn importNames(a: std.mem.Allocator, gpa: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const facts = Token.scan(scratch.allocator(), bytes, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (facts.imports) |import| {
        var seen = false;
        for (out.items) |name| seen = seen or std.mem.eql(u8, name, import.name);
        if (!seen) try out.append(a, try a.dupe(u8, import.name));
    }
    return out.items;
}

/// A package as its `build.zig.zon` names it: `.name` and `.fingerprint`, each where written.
pub const Manifest = struct {
    name: []const u8 = "",
    fingerprint: ?u64 = null,

    pub fn parse(a: std.mem.Allocator, bytes: [:0]const u8) !Manifest {
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

const Loader = struct {
    a: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The project file's root: every path is read relative to it. The caller keeps and closes it.
    dir: aegis.own.Unowned(std.Io.Dir),
    modules: []const ProjectFile.Module,
    std_dir: ?[]const u8,
    std_file: ?[]const u8,
    problems: *std.Io.Writer,
    /// A file's bytes, once read; null for a file that is not there.
    bytes: std.StringHashMapUnmanaged(?[:0]const u8) = .empty,
    /// The build's modules, read over the files: empty until `membership`.
    map: ModuleMap = .{ .modules = &.{} },
    /// What a file imports, by name, scanned once.
    names: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    inputs: std.ArrayList(Project.Input) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    /// The identity a directory's own `build.zig.zon` gives; null where it has none.
    manifests: std.StringHashMapUnmanaged(?Manifest) = .empty,
    total: usize = 0,

    pub fn read(self: *Loader, path: []const u8) !?[:0]const u8 {
        const entry = try self.bytes.getOrPut(self.a, path);
        if (entry.found_existing) return entry.value_ptr.*;
        // A module the build generates whole as it configures: its text, which is on no disk.
        for (self.modules) |module| if (module.contents) |contents| if (module.root) |root| {
            if (!std.mem.eql(u8, try normalize(self.a, root), path)) continue;
            entry.value_ptr.* = try self.a.dupeSentinel(u8, contents, 0);
            return entry.value_ptr.*;
        };
        entry.value_ptr.* = aegis.own.readFileSentinel(self.io, self.dir.get(), path, self.a, .fromRaw(16 * 1024 * 1024), 0) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => {
                _ = self.bytes.remove(path);
                try self.problems.print("{s}: not read ({t})\n", .{ path, err });
                return error.InputUnreadable;
            },
        };
        return entry.value_ptr.*;
    }

    /// What `bytes` imports, each name once. A file whose literals do not scan has no names: the
    /// project's own parse of it reports the file as unusable.
    pub fn importsOf(self: *Loader, path: []const u8, bytes: []const u8) ![]const []const u8 {
        const entry = try self.names.getOrPut(self.a, path);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = &.{};
        entry.value_ptr.* = try importNames(self.a, self.gpa, bytes);
        return entry.value_ptr.*;
    }

    /// Which modules compile each file their roots reach.
    fn membership(self: *Loader) !void {
        self.map = try ModuleMap.init(self.a, self.modules, self);
    }

    /// Which compilations compile each input, as its imports are read in them: the program's
    /// where a module of the program's compiles it, the build runner's where a build script's
    /// does, and every compilation of each file that imports it. A file no module compiles and
    /// nothing compiled imports is the program's.
    fn compilations(self: *Loader, imports: []const Project.Import) !void {
        const program = try self.a.alloc(bool, self.inputs.items.len);
        const build = try self.a.alloc(bool, self.inputs.items.len);
        for (self.inputs.items, program, build) |input, *in_program, *in_build| {
            in_program.* = false;
            in_build.* = false;
            for (self.map.modulesOf(input.name)) |which| {
                if (self.modules[which].script) in_build.* = true else in_program.* = true;
            }
        }
        spread(imports, program, build);
        for (program, build) |*in_program, in_build| in_program.* = in_program.* or !in_build;
        spread(imports, program, build);
        for (self.inputs.items, program, build) |*input, in_program, in_build| {
            input.compilations = if (in_program and in_build) .both else if (in_build) .build else .program;
        }
    }

    /// Each compilation of a file to every file it imports in that compilation, until none is
    /// added.
    fn spread(imports: []const Project.Import, program: []bool, build: []bool) void {
        var growing = true;
        while (growing) {
            growing = false;
            for (imports) |edge| for ([_]Project.Compilations{ .program, .build }) |in| {
                if (edge.compilation) |only| if (only != in) continue;
                const set = if (in == .program) program else build;
                if (set[edge.from] and !set[edge.target]) {
                    set[edge.target] = true;
                    growing = true;
                }
            };
        }
    }

    fn insideStd(self: *Loader, path: []const u8) bool {
        const dir = self.std_dir orelse return false;
        return std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/';
    }

    /// The package whose tree holds `path`: the identity of the nearest `build.zig.zon` above it,
    /// the checked package's own included. None for std's files, and none where no directory up
    /// to the root (or, outside it, the filesystem's root) has one.
    fn packageOf(self: *Loader, path: []const u8) !Manifest {
        if (self.insideStd(path)) return .{};
        const outside = std.mem.startsWith(u8, path, "..") or std.Io.Dir.path.isAbsolute(path);
        var dir = std.Io.Dir.path.dirname(path);
        while (dir) |at| : (dir = std.Io.Dir.path.dirname(at)) {
            if (try self.manifestOf(at)) |found| return found;
        }
        if (!outside) if (try self.manifestOf("")) |found| return found;
        return .{};
    }

    fn manifestOf(self: *Loader, dir: []const u8) !?Manifest {
        const entry = try self.manifests.getOrPut(self.a, dir);
        if (entry.found_existing) return entry.value_ptr.*;
        const path = try std.Io.Dir.path.join(self.a, &.{ dir, "build.zig.zon" });
        entry.value_ptr.* = if (aegis.own.readFileSentinel(self.io, self.dir.get(), path, self.a, .fromRaw(1024 * 1024), 0)) |bytes|
            try Manifest.parse(self.a, bytes)
        else |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => {
                _ = self.manifests.remove(dir);
                try self.problems.print("{s}: not read ({t})\n", .{ path, err });
                return error.InputUnreadable;
            },
        };
        return entry.value_ptr.*;
    }

    /// Adds a file to the project, once; null when it is not there.
    fn load(self: *Loader, path: []const u8, selected: bool, kind: ProjectFile.Kind) !?u32 {
        if (self.index.get(path)) |known| {
            if (selected) self.inputs.items[known].selected = true;
            return known;
        }
        if (std.mem.startsWith(u8, path, "<external ")) {
            const id: u32 = @intCast(self.inputs.items.len);
            try self.inputs.append(self.a, .{ .name = path, .bytes = "", .stem = path["<external ".len .. path.len - 1], .selected = false, .external = true });
            try self.index.put(self.a, path, id);
            return id;
        }
        const bytes = (try self.read(path)) orelse return null;
        if (self.inputs.items.len >= max_files or bytes.len > max_bytes - self.total) return error.ProjectBudgetExceeded;
        self.total += bytes.len;
        const id: u32 = @intCast(self.inputs.items.len);
        const base = std.Io.Dir.path.basename(path);
        const package = try self.packageOf(path);
        try self.inputs.append(self.a, .{
            .name = path,
            .bytes = bytes,
            .stem = if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - 4] else base,
            // A ZON file a Zig file imports is data, read as ZON.
            .kind = if (std.mem.endsWith(u8, base, ".zon")) .zon else .zig,
            .selected = selected,
            .classification = if (kind == .production) .production else .@"test",
            .package = package.name,
            .fingerprint = package.fingerprint,
        });
        try self.index.put(self.a, path, id);
        return id;
    }

    /// Where an import written in `from` leads in each compilation that compiles it: each file a
    /// module that compiles it binds the name to, several a choice read as any.
    const Lead = struct {
        /// Where it leads in every compilation of the file; empty where it leads nowhere.
        every: []const []const u8 = &.{},
        /// Where it leads in the program's and in the build runner's, when they bind it apart.
        program: []const []const u8 = &.{},
        build: []const []const u8 = &.{},
    };

    /// Where an import written in `from` leads: `std`, a module the build binds the name to
    /// (whatever the name ends with: gantry's Zig front end is the module `gantry.zig`), or else
    /// a relative file. The program and the build runner bind names apart: a file both compile
    /// leads to each one's modules, an edge apiece. Two modules of one compilation that both
    /// compile the file and bind the name to different files lead to each there, a choice; a
    /// binding to a module with no root file leads to it as external.
    fn lead(self: *Loader, from: []const u8, name: []const u8) !Lead {
        if (std.mem.eql(u8, name, "std")) return .{ .every = if (self.std_file) |file| try self.a.dupe([]const u8, &.{file}) else &.{} };
        const program = try self.map.bound(self.a, from, name, .program);
        const build = try self.map.bound(self.a, from, name, .build);
        if (program == .unbound and build == .unbound) {
            if (!relativeFile(name)) return .{};
            const path = try join(self.a, std.Io.Dir.path.dirname(from) orelse "", name);
            const outside = std.mem.startsWith(u8, path, "..") or std.Io.Dir.path.isAbsolute(path);
            if (outside and !self.insideStd(path) and !self.map.compiles(path)) return .{};
            return .{ .every = try self.a.dupe([]const u8, &.{path}) };
        }
        const in_program: []const []const u8 = if (program == .paths) program.paths else &.{};
        const in_build: []const []const u8 = if (build == .paths) build.paths else &.{};
        // The same modules wherever the name is bound: the edges hold in every compilation.
        if (in_program.len == 0 or in_build.len == 0 or samePaths(in_program, in_build))
            return .{ .every = if (in_program.len != 0) in_program else in_build };
        return .{ .program = in_program, .build = in_build };
    }

    /// Whether two lists name the same files, in any order.
    fn samePaths(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a) |one| {
            for (b) |other| {
                if (std.mem.eql(u8, one, other)) break;
            } else return false;
        }
        return true;
    }

    /// Whether the build binds no module named `name` in any module that compiles `from`: a
    /// module this build does not have there. A name ending in `.zig` or `.zon` is a file, as Zig
    /// reads it, never a module; Zig's own names (`std`, `builtin`, `root`) are always there, and a
    /// file no module compiles has no bindings to go by.
    fn absent(self: *Loader, from: []const u8, name: []const u8) !bool {
        if (!moduleName(name)) return false;
        if (!self.map.compiles(from)) return false;
        return try self.map.bound(self.a, from, name, .program) == .unbound and try self.map.bound(self.a, from, name, .build) == .unbound;
    }

    /// Whether an import names a module: not a file (`.zig`, `.zon`) and not one of Zig's own.
    fn moduleName(name: []const u8) bool {
        if (relativeFile(name)) return false;
        for ([_][]const u8{ "std", "builtin", "root" }) |own| if (std.mem.eql(u8, name, own)) return false;
        return true;
    }
};

/// Reads the project file's selected files, its build scripts and every file their imports
/// reach, and records each import as the build binds it. `dir` is the project file's root. A
/// selected file that is not there, or that no module of a build with modules compiles while it
/// imports a module by name, is named on `problems` and refused.
pub fn assemble(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, project: ProjectFile, problems: *std.Io.Writer) Error!Assembled {
    const std_dir = if (project.zig_lib) |lib| try join(a, lib, "std") else null;
    var loader: Loader = .{
        .a = a,
        .gpa = gpa,
        .io = io,
        .dir = .of(dir),
        .modules = project.modules,
        .std_dir = std_dir,
        .std_file = if (std_dir) |at| try join(a, at, "std.zig") else null,
        .problems = problems,
    };
    for (project.files) |file| {
        const path = try normalize(a, file.path);
        _ = (try loader.load(path, true, file.kind)) orelse {
            try problems.print("{s}: not found\n", .{path});
            return error.InputNotFound;
        };
    }
    // Every build script the build compiles is read, unselected, though no selected file imports
    // it: the root bay writes binds the package's `dev(b, tools)` there, a binding a rule judges
    // `dev`'s body at.
    for (project.modules) |module| if (module.script) if (module.root) |root| {
        _ = try loader.load(try normalize(a, root), false, .production);
    };
    try loader.membership();

    var imports: std.ArrayList(Project.Import) = .empty;
    var uncompiled_named = false;
    var cursor: usize = 0;
    while (cursor < loader.inputs.items.len) : (cursor += 1) {
        try io.checkCancel();
        const from = loader.inputs.items[cursor];
        var absent: std.ArrayList([]const u8) = .empty;
        // A selected file no module of the build compiles is in none of its compilations: a
        // module name it imports has no binding to read, which is named once for the file.
        const uncompiled = from.selected and project.modules.len != 0 and !loader.map.compiles(from.name);
        var unbound: ?[]const u8 = null;
        for (try loader.importsOf(from.name, from.bytes)) |name| {
            const lead = try loader.lead(from.name, name);
            if (lead.every.len == 0 and lead.program.len == 0 and lead.build.len == 0) {
                if (try loader.absent(from.name, name)) {
                    try absent.append(a, name);
                } else if (uncompiled and Loader.moduleName(name)) {
                    try absent.append(a, name);
                    if (unbound == null) unbound = name;
                }
                continue;
            }
            const leads = [_]struct { []const []const u8, ?Project.Compilations }{
                .{ lead.every, null }, .{ lead.program, .program }, .{ lead.build, .build },
            };
            for (leads) |each| {
                const targets, const compilation = each;
                for (targets) |path| {
                    const found = (try loader.load(path, false, .production)) orelse continue;
                    try imports.append(a, .{ .from = cursor, .spelling = name, .target = found, .compilation = compilation });
                }
            }
        }
        loader.inputs.items[cursor].absent = try absent.toOwnedSlice(a);
        if (unbound) |name| {
            try problems.print("{s}: no module of this build compiles it, so `{s}` and every module it imports have no binding to read: build it in the package's own graph (its `check`), or leave it out of what glint reads\n", .{ from.name, name });
            uncompiled_named = true;
        }
    }
    if (uncompiled_named) return error.InputNotCompiled;
    try loader.compilations(imports.items);
    // The roots of the modules the package exports: the public surface starts there.
    for (project.exported) |module| {
        const path = try normalize(a, module.root);
        for (loader.inputs.items) |*input| if (std.mem.eql(u8, input.name, path)) {
            input.exported = true;
        };
    }
    return .{ .inputs = loader.inputs.items, .imports = imports.items };
}

/// A project file over files written into a test's directory: the assembly it gives.
fn assembleIn(arena: std.mem.Allocator, tmp: *std.testing.TmpDir, files: []const [2][]const u8, project_json: []const u8, problems: *std.Io.Writer) !Assembled {
    for (files) |file| {
        if (std.Io.Dir.path.dirname(file[0])) |parent| try tmp.dir.createDirPath(std.testing.io, parent);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file[0], .data = file[1] });
    }
    const project = try Contract.readProject(arena, project_json, problems);
    return assemble(arena, std.testing.allocator, std.testing.io, tmp.dir, project, problems);
}

fn inputNamed(assembled: Assembled, name: []const u8) ?usize {
    for (assembled.inputs, 0..) |input, i| if (std.mem.eql(u8, input.name, name)) return i;
    return null;
}

test "an import leads where the build binds it, a file by its path, and a name no module binds is absent" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var problems: std.Io.Writer.Allocating = .init(arena.allocator());
    const assembled = try assembleIn(arena.allocator(), &tmp, &.{
        .{ "src/main.zig", "const dep = @import(\"dep\");\nconst x = @import(\"x.zig\");\nconst gone = @import(\"gone\");\n" },
        .{ "src/dep.zig", "pub const v = 1;\n" },
        .{ "src/x.zig", "pub const w = 2;\n" },
        .{ "build.zig", "pub fn build() void {}\n" },
    },
        \\{"version": 1, "root": ".",
        \\ "modules": [{"root": "src/main.zig", "imports": [{"name": "dep", "module": 1}]}, {"root": "src/dep.zig"}, {"root": "build.zig", "script": true}],
        \\ "files": [{"path": "src/main.zig", "kind": "production", "ships": true, "max_function_lines": 120}],
        \\ "policy": {"levels": [], "shipped_bans": [], "fact_budget": 1}}
    , &problems.writer);
    try std.testing.expectEqualStrings("", problems.written());
    const main = inputNamed(assembled, "src/main.zig").?;
    try std.testing.expectEqual(@as(usize, 0), main);
    try std.testing.expect(assembled.inputs[main].selected);
    try std.testing.expectEqual(@as(usize, 1), assembled.inputs[main].absent.len);
    try std.testing.expectEqualStrings("gone", assembled.inputs[main].absent[0]);
    const script = inputNamed(assembled, "build.zig").?;
    try std.testing.expect(!assembled.inputs[script].selected);
    try std.testing.expectEqual(Project.Compilations.build, assembled.inputs[script].compilations);
    const dep = inputNamed(assembled, "src/dep.zig").?;
    const x = inputNamed(assembled, "src/x.zig").?;
    var to_dep = false;
    var to_x = false;
    for (assembled.imports) |edge| {
        if (edge.from == main and edge.target == dep and std.mem.eql(u8, edge.spelling, "dep")) to_dep = true;
        if (edge.from == main and edge.target == x and std.mem.eql(u8, edge.spelling, "x.zig")) to_x = true;
    }
    try std.testing.expect(to_dep and to_x);
    try std.testing.expectEqual(Project.Compilations.program, assembled.inputs[dep].compilations);
}

test "a selected file no module of the build compiles, importing a module by name, is named and refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var problems: std.Io.Writer.Allocating = .init(arena.allocator());
    try std.testing.expectError(error.InputNotCompiled, assembleIn(arena.allocator(), &tmp, &.{
        .{ "src/main.zig", "pub const v = 1;\n" },
        .{ "tools/gen.zig", "const dep = @import(\"dep\");\n" },
    },
        \\{"version": 1, "root": ".",
        \\ "modules": [{"root": "src/main.zig"}],
        \\ "files": [{"path": "tools/gen.zig", "kind": "production", "ships": false, "max_function_lines": null}],
        \\ "policy": {"levels": [], "shipped_bans": [], "fact_budget": 1}}
    , &problems.writer));
    try std.testing.expect(std.mem.startsWith(u8, problems.written(), "tools/gen.zig: no module of this build compiles it, so `dep`"));
}

test "a selected file that is not there is named" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var problems: std.Io.Writer.Allocating = .init(arena.allocator());
    try std.testing.expectError(error.InputNotFound, assembleIn(arena.allocator(), &tmp, &.{},
        \\{"version": 1, "root": ".", "files": [{"path": "src/gone.zig", "kind": "production", "ships": true, "max_function_lines": 120}],
        \\ "policy": {"levels": [], "shipped_bans": [], "fact_budget": 1}}
    , &problems.writer));
    try std.testing.expectEqualStrings("src/gone.zig: not found\n", problems.written());
}
