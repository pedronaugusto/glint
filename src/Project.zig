//! An owned immutable project. Inputs and import mappings are supplied by callers.
const std = @import("std");
const File = @import("File.zig");
const Model = @import("Model.zig");
const Project = @This();
const aegis = @import("aegis");

/// Private: allocation owner for frozen project indexes.
arena: std.heap.ArenaAllocator,
/// Private: per-source front ends, bindings and caller classification, one entry per input
/// in the caller's order.
sources: []Source,
/// Private: explicit module resolution. There is no filesystem or path policy here.
imports: []const Edge,
/// Private: distinguishes handles from separate snapshots, even at the same index.
identity: u64,
/// Private: the store this project made for itself when its caller gave none.
own: ?*Store,
/// The store its files were read through: a project made of some of them (a unit's,
/// `Taint`'s open world) reads them from it again, parsed once.
store: *Store,

/// One source: its front end, its model (which refers only to this immutable file), and the
/// input it was made from.
pub const Source = struct {
    file: *const File,
    model: Model,
    input: Input,
    id: Id,

    /// A source within one project, made only by `init` counting the sources: an id names
    /// one of them. A caller turns its input's position into one with `fileAt`.
    pub const Id = enum(u32) { _ };
};
/// A source within one project.
pub const FileId = Source.Id;
/// Distinct source AST indices; conversions to std occur only at query boundaries.
pub const NodeId = aegis.id.Id(struct {}, u32);
/// Token identities cannot be confused with node or file identities.
pub const TokenId = aegis.id.Id(struct {}, u32);
/// A source handle that cannot silently identify a replacement snapshot.
pub const Handle = struct { file: FileId, snapshot: u64 };
/// Explicit source data. `name` is a diagnostic label; `stem` is Zig file-struct naming input.
/// The name Zig binds to its standard library in every module, which no build module can take:
/// the one spelling std's files are known by (`Facts.outside`).
pub const std_module = "std";

pub const Input = struct {
    name: []const u8,
    bytes: []const u8,
    /// What the bytes are, as the caller states it: Zig source, or ZON data a Zig file imports
    /// (`@import("build.zig.zon")`). A ZON file is data, never code: it is parsed, not lowered,
    /// and no rule reads it but through the value an import of it resolves to.
    kind: File.Kind = .zig,
    stem: []const u8 = "",
    selected: bool = true,
    classification: enum { production, @"test", generated } = .production,
    /// Module names the build binds in no module that compiles this file. Zig compiles an
    /// `@import` of one only where the build would fail, so code that needs one is not part of
    /// this build. The caller states this from the build's own configuration; a name merely
    /// left unmapped stays unknown.
    absent: []const []const u8 = &.{},
    /// The package whose tree holds this file: the name its nearest `build.zig.zon` gives, as
    /// the caller states it. Empty when unknown. A policy names packages by it (an owner of a
    /// disallowed declaration).
    package: []const u8 = "",
    /// That package's identity: the fingerprint its `build.zig.zon` gives, as the caller states
    /// it. Null when unknown. A library the analyses know (aegis) is known by its name and
    /// this, under whatever name a program imports it.
    fingerprint: ?u64 = null,
    /// The compilations that compile this file, as the caller's build has them. Each names its
    /// modules apart: a build script's `@import("aegis")` is the aegis dependency's build
    /// script, the program's is aegis's module. An import is read in the compilations of the
    /// file that makes it, never by its spelling in another.
    compilations: Compilations = .program,
};
/// The compilations that compile a file.
pub const Compilations = enum {
    /// The program's alone: its modules and their tests.
    program,
    /// The build runner's alone: a build script and the files it imports.
    build,
    /// Both: a file a build script imports that the program's modules compile too.
    both,

    /// Whether the program's compilation compiles the file.
    pub fn inProgram(self: Compilations) bool {
        return self != .build;
    }
    /// Whether every compilation that compiles a file of `self` compiles one of `other`: what
    /// a file's import reaches, each compilation compiling the file compiles too.
    pub fn within(self: Compilations, other: Compilations) bool {
        return self == other or other == .both;
    }
    /// Whether no compilation compiles a file of both.
    pub fn apart(self: Compilations, other: Compilations) bool {
        return self != other and self != .both and other != .both;
    }
};
/// A module edge selected and resolved by the caller, never by a path hash: `from` and `target`
/// are positions in the inputs given to `init`.
pub const Import = struct {
    from: usize,
    spelling: []const u8,
    target: usize,
    /// The one compilation the edge holds in, where a file both compile binds the name apart in
    /// each (`aegis`: the library in the program's, the dependency's build script in the build
    /// runner's): an edge for each, and the name reaches both. Null: every compilation that
    /// compiles `from`.
    compilation: ?Compilations = null,
};
/// An import checked against the inputs, and the compilations it holds in.
pub const Edge = struct { from: FileId, spelling: []const u8, target: FileId, in: Compilations };
/// Per-source limits for front-end work.
pub const Options = struct {
    lowering: bool = true,
    limits: File.Limits = .{},
    files: usize = 4096,
    bytes: usize = 128 * 1024 * 1024,
    /// The caller's `Io`, asked for a cancel before each file is parsed and
    /// lowered: a canceled build is `Canceled`. Null: none is asked, and a
    /// canceller waits for every file.
    io: ?std.Io = null,
    /// Where the files are read: a store several projects share reads each file once, std's
    /// among them. Null: the project reads its own.
    store: ?*Store = null,
    /// Where `store` is null: a frozen store the project's own reads first, through a const
    /// pointer, so that nothing is written to it; what it lacks the project's own store reads.
    /// Several projects, one after another or at once, share it.
    base: ?*const Store = null,
};

/// Files read once and shared by every project made with this store: what a file means on its
/// own, its bytes, tree, ZIR and per-file model, kept by its bytes and the kind, limits and
/// lowering it was read under. Nothing a program's other files decide is kept here: what the analyses
/// find of a program is each run's own. The caller owns it, and it outlives every project made
/// with it; one thread uses it at a time.
pub const Store = struct {
    gpa: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(u64, std.ArrayList(*Entry)) = .empty,
    /// A frozen store read before this one, through a const pointer: what it holds is never
    /// read again, and this store keeps only what it lacks.
    base: ?*const Store = null,

    const Entry = struct { file: File, model: Model, limits: File.Limits, lowering: bool, kind: File.Kind };

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    /// A store that reads `base` first and writes nothing to it.
    pub fn over(gpa: std.mem.Allocator, base: *const Store) Store {
        return .{ .gpa = gpa, .base = base };
    }

    /// The file this store or its base read before from `bytes` so, if one did: a lookup only.
    fn find(self: *const Store, bytes: []const u8, limits: File.Limits, lowering: bool, kind: File.Kind) ?*const Entry {
        if (self.base) |base| if (base.find(bytes, limits, lowering, kind)) |entry| return entry;
        const list = self.entries.get(std.hash.Wyhash.hash(0, bytes)) orelse return null;
        for (list.items) |entry| {
            if (entry.kind == kind and entry.lowering == lowering and std.meta.eql(entry.limits, limits) and std.mem.eql(u8, entry.file.source, bytes)) return entry;
        }
        return null;
    }

    pub fn deinit(self: *Store) void {
        var each = self.entries.valueIterator();
        while (each.next()) |list| {
            for (list.items) |entry| {
                entry.file.deinit();
                self.gpa.destroy(entry);
            }
            list.deinit(self.gpa);
        }
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// The file `bytes` are, read as `kind` under `limits`: the one this store read before from
    /// the same bytes so, or one read now. The same bytes read as Zig and as ZON are two files.
    fn read(self: *Store, bytes: []const u8, limits: File.Limits, lowering: bool, kind: File.Kind) (File.InitError || Model.InitError)!*const Entry {
        if (self.find(bytes, limits, lowering, kind)) |entry| return entry;
        const found = try self.entries.getOrPut(self.gpa, std.hash.Wyhash.hash(0, bytes));
        if (!found.found_existing) found.value_ptr.* = .empty;
        const entry = try self.gpa.create(Entry);
        errdefer self.gpa.destroy(entry);
        entry.file = try File.initWithLowering(self.gpa, bytes, limits, lowering, kind);
        errdefer entry.file.deinit();
        entry.model = try Model.init(&entry.file);
        entry.limits = limits;
        entry.lowering = lowering;
        entry.kind = kind;
        try found.value_ptr.append(self.gpa, entry);
        return entry;
    }
};
/// Construction errors always propagate; no unread/allocation failure is clean.
pub const InitError = File.InitError || Model.InitError || std.Io.Cancelable || error{ InvalidMapping, DuplicateMapping, ProjectBudgetExceeded, SnapshotLimit };
/// A handle from another snapshot is invalid.
pub const QueryError = error{InvalidHandle};

/// Copies all source inputs and lowers each valid file through std AstGen/ZIR.
pub fn init(gpa: std.mem.Allocator, inputs: []const Input, imports: []const Import, options: Options) InitError!Project {
    if (inputs.len > options.files or inputs.len > std.math.maxInt(u32)) return error.ProjectBudgetExceeded;
    var remaining_bytes = aegis.int.Checked(usize).init(options.bytes);
    for (inputs) |input| {
        remaining_bytes = remaining_bytes.sub(input.bytes.len) catch return error.ProjectBudgetExceeded;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const own: ?*Store = if (options.store == null) try a.create(Store) else null;
    if (own) |store| store.* = if (options.base) |base| .over(gpa, base) else .init(gpa);
    errdefer if (own) |store| store.deinit();
    const store = options.store orelse own.?;
    const sources = try a.alloc(Source, inputs.len);
    for (sources, inputs, 0..) |*each, input, index| {
        if (options.io) |io| try io.checkCancel();
        each.id = @fromBackingInt(@intCast(index));
        const entry = try store.read(input.bytes, options.limits, options.lowering, input.kind);
        each.file = &entry.file;
        each.model = entry.model;
        each.input = input;
        each.input.bytes = each.file.source;
        each.input.name = try a.dupe(u8, input.name);
        each.input.stem = try a.dupe(u8, input.stem);
        each.input.package = try a.dupe(u8, input.package);
        const names = try a.alloc([]const u8, input.absent.len);
        for (names, input.absent) |*out, name| out.* = try a.dupe(u8, name);
        each.input.absent = names;
    }
    const mappings = try a.alloc(Edge, imports.len);
    for (mappings, imports, 0..) |*mapping, import, index| {
        if (import.from >= sources.len or import.target >= sources.len) return error.InvalidMapping;
        // An import is made in each compilation it holds in, all that compile its file unless it
        // names one of them; each compiles its target.
        const in = import.compilation orelse inputs[import.from].compilations;
        if (!in.within(inputs[import.from].compilations) or !in.within(inputs[import.target].compilations)) return error.InvalidMapping;
        mapping.* = .{ .from = sources[import.from].id, .spelling = try a.dupe(u8, import.spelling), .target = sources[import.target].id, .in = in };
        // A name has one binding in each compilation: two edges hold in one apiece.
        for (mappings[0..index]) |earlier| if (mapping.from == earlier.from and std.mem.eql(u8, mapping.spelling, earlier.spelling) and !mapping.in.apart(earlier.in)) return error.DuplicateMapping;
    }
    const identity = try nextIdentity();
    return .{ .arena = arena, .sources = sources, .imports = mappings, .identity = identity, .own = own, .store = store };
}

/// Releases all owned source/front-end/model storage; a store the caller gave stays.
pub fn deinit(self: *Project) void {
    if (self.own) |store| store.deinit();
    self.arena.deinit();
    self.* = undefined;
}

/// The source made from the input at `position` in the inputs given to `init`.
pub fn fileAt(self: *const Project, position: usize) QueryError!FileId {
    if (position >= self.sources.len) return error.InvalidHandle;
    return self.sources[position].id;
}

/// A source by its id.
pub fn at(self: *const Project, file: FileId) *const Source {
    return &self.sources[@backingInt(file)];
}

/// Creates a handle for an existing source.
pub fn handle(self: *const Project, file: FileId) Handle {
    return .{ .file = file, .snapshot = self.identity };
}

/// Returns a source's lexical references with resolved declaration identity or unknown reason.
pub fn references(self: *const Project, source_handle: Handle) QueryError![]const Model.Reference {
    return (try self.checked(source_handle)).model.references;
}

/// Source-mapped call/member/reflection operations from actual std ZIR bodies.
pub fn operations(self: *const Project, h: Handle) QueryError![]const Model.Operation {
    return (try self.checked(h)).model.operations;
}

/// Returns source declarations, including lazy declarations and public/export provenance.
pub fn declarations(self: *const Project, source_handle: Handle) QueryError![]const Model.Declaration {
    return (try self.checked(source_handle)).model.declarations;
}

/// Returns lexical scopes; fields and enum literals are not binding references.
pub fn scopes(self: *const Project, source_handle: Handle) QueryError![]const Model.Scope {
    return (try self.checked(source_handle)).model.scopes;
}

/// Returns immutable source bytes for source-span consumers.
pub fn source(self: *const Project, source_handle: Handle) QueryError![]const u8 {
    return (try self.checked(source_handle)).input.bytes;
}

/// The file an import of `spelling` in `from` reaches in the program's compilation, or in the
/// only one that compiles `from`; null when no mapping was supplied. `importedAll` gives each.
pub fn imported(self: *const Project, from: FileId, spelling: []const u8) ?FileId {
    var buffer: [2]FileId = undefined;
    const all = self.importedAll(from, spelling, &buffer);
    for (self.imports) |mapping| if (mapping.from == from and std.mem.eql(u8, mapping.spelling, spelling) and mapping.in.inProgram()) return mapping.target;
    return if (all.len == 0) null else all[0];
}

/// The files an import of `spelling` in `from` reaches, as the caller mapped it: one, or one in
/// each compilation where a file both compile binds the name apart; none when no mapping was
/// supplied.
pub fn importedAll(self: *const Project, from: FileId, spelling: []const u8, buffer: *[2]FileId) []const FileId {
    var found: usize = 0;
    for (self.imports) |mapping| if (mapping.from == from and std.mem.eql(u8, mapping.spelling, spelling)) {
        buffer[found] = mapping.target;
        found += 1;
        if (found == buffer.len) break;
    };
    return buffer[0..found];
}

/// Whether the build binds no module named `spelling` for `from` (its input's `absent`).
pub fn absent(self: *const Project, from: FileId, spelling: []const u8) bool {
    for (self.at(from).input.absent) |name| if (std.mem.eql(u8, name, spelling)) return true;
    return false;
}

/// Number of source inputs, including unselected dependencies.
pub fn count(self: *const Project) usize {
    return self.sources.len;
}
/// Caller-provided source classification and diagnostic identity.
pub fn metadata(self: *const Project, h: Handle) QueryError!Input {
    return (try self.checked(h)).input;
}
/// Frozen std AST. Invalid inputs retain syntax but cannot supply semantic facts.
pub fn syntax(self: *const Project, h: Handle) QueryError!*const std.zig.Ast {
    return &(try self.checked(h)).file.tree;
}
/// Frozen std ZIR, absent when parsing failed.
pub fn lowered(self: *const Project, h: Handle) QueryError!?*const std.zig.Zir {
    const file = (try self.checked(h)).file;
    return if (file.zir) |*zir| zir else null;
}
/// Honest front-end status, independent of selected rules.
pub fn status(self: *const Project, h: Handle) QueryError!File.Status {
    return (try self.checked(h)).file.status;
}
/// Real tokenizer comments; strings and multiline strings cannot forge a reason.
pub fn comments(self: *const Project, h: Handle) QueryError![]const File.Comment {
    return (try self.checked(h)).file.comments;
}
/// Validates distinct node identity before converting to std's AST index.
pub fn node(self: *const Project, h: Handle, id: NodeId) QueryError!std.zig.Ast.Node.Index {
    // glint-ignore: A004 -- an identity checked against the length of the table it indexes; the comparison is the bound
    if (id.raw() >= (try self.syntax(h)).nodes.len) return error.InvalidHandle;
    return @fromBackingInt(id.raw());
}
/// Validates distinct token identity before crossing the std boundary.
pub fn token(self: *const Project, h: Handle, id: TokenId) QueryError!std.zig.Ast.TokenIndex {
    // glint-ignore: A004 -- an identity checked against the length of the table it indexes; the comparison is the bound
    if (id.raw() >= (try self.syntax(h)).tokens.len) return error.InvalidHandle;
    return id.raw();
}

// Process-local identities are monotonic; allocator reuse cannot revive stale handles.
const Identity = enum(u64) { _ };
const no_identity: Identity = @fromBackingInt(0);
var last_identity: aegis.Atomic(Identity) = .init(no_identity);
fn nextIdentity() error{SnapshotLimit}!u64 {
    var previous = last_identity.load(.monotonic);
    while (true) {
        const raw = @backingInt(previous);
        if (raw == std.math.maxInt(u64)) return error.SnapshotLimit;
        if (last_identity.cmpxchgWeak(previous, @fromBackingInt(raw + 1), .monotonic, .monotonic)) |observed| previous = observed else return raw + 1;
    }
}

fn checked(self: *const Project, source_handle: Handle) QueryError!*const Source {
    if (source_handle.snapshot != self.identity) return error.InvalidHandle;
    return self.at(source_handle.file);
}

test "project handles cannot refer to another snapshot" {
    var first = try init(std.testing.allocator, &.{.{ .name = "one", .bytes = "const x = 1;" }}, &.{}, .{});
    defer first.deinit();
    var second = try init(std.testing.allocator, &.{.{ .name = "two", .bytes = "const x = 2;" }}, &.{}, .{});
    defer second.deinit();
    const h = first.handle(try first.fileAt(0));
    try std.testing.expectError(error.InvalidHandle, second.source(h));
    try std.testing.expectEqualStrings("const x = 1;", try first.source(h));
}

test "project maps opaque module identities without filesystem access" {
    var project = try init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = "const dep = @import(\"dep\");" },
        .{ .name = "other", .bytes = "pub const value = 1;", .selected = false },
    }, &.{.{ .from = 0, .spelling = "dep", .target = 1 }}, .{});
    defer project.deinit();
    try std.testing.expectEqual(@as(?FileId, try project.fileAt(1)), project.imported(try project.fileAt(0), "dep"));
    try std.testing.expectEqual(null, project.imported(try project.fileAt(0), "missing"));
}

test "a name a file both compilations compile binds apart reaches each compilation's target" {
    const inputs = [_]Input{
        .{ .name = "shared", .bytes = "const dep = @import(\"dep\");", .compilations = .both },
        .{ .name = "dep/root", .bytes = "pub const value = 1;" },
        .{ .name = "dep/build", .bytes = "pub fn build() void {}", .compilations = .build },
        .{ .name = "dep/both", .bytes = "pub const value = 1;", .compilations = .both },
    };
    var project = try init(std.testing.allocator, &inputs, &.{
        .{ .from = 0, .spelling = "dep", .target = 1, .compilation = .program },
        .{ .from = 0, .spelling = "dep", .target = 2, .compilation = .build },
    }, .{});
    defer project.deinit();
    var buffer: [2]FileId = undefined;
    try std.testing.expectEqualSlices(FileId, &.{ try project.fileAt(1), try project.fileAt(2) }, project.importedAll(try project.fileAt(0), "dep", &buffer));
    try std.testing.expectEqual(@as(?FileId, try project.fileAt(1)), project.imported(try project.fileAt(0), "dep"));
    // Two bindings in one compilation, an edge in every compilation beside one in a single one,
    // and an edge in a compilation that does not compile its file or its target, are refused.
    try std.testing.expectError(error.DuplicateMapping, init(std.testing.allocator, &inputs, &.{
        .{ .from = 0, .spelling = "dep", .target = 1, .compilation = .program },
        .{ .from = 0, .spelling = "dep", .target = 1, .compilation = .program },
    }, .{}));
    try std.testing.expectError(error.DuplicateMapping, init(std.testing.allocator, &inputs, &.{
        .{ .from = 0, .spelling = "dep", .target = 3 },
        .{ .from = 0, .spelling = "dep", .target = 2, .compilation = .build },
    }, .{}));
    try std.testing.expectError(error.InvalidMapping, init(std.testing.allocator, &inputs, &.{.{ .from = 1, .spelling = "dep", .target = 2, .compilation = .build }}, .{}));
    try std.testing.expectError(error.InvalidMapping, init(std.testing.allocator, &inputs, &.{.{ .from = 0, .spelling = "dep", .target = 1, .compilation = .build }}, .{}));
}

test "an import reaches only a file each compilation of its own compiles" {
    // A build script's import of its dependency's script, and a program file both compile.
    for ([_]struct { Compilations, Compilations, bool }{
        .{ .build, .build, true },
        .{ .program, .both, true },
        .{ .both, .both, true },
        .{ .program, .build, false },
        .{ .build, .program, false },
        .{ .both, .program, false },
    }) |case| {
        const inputs = [_]Input{
            .{ .name = "from", .bytes = "const dep = @import(\"dep\");", .compilations = case[0] },
            .{ .name = "dep", .bytes = "pub const value = 1;", .compilations = case[1] },
        };
        var project = init(std.testing.allocator, &inputs, &.{.{ .from = 0, .spelling = "dep", .target = 1 }}, .{}) catch |err| {
            try std.testing.expectEqual(error.InvalidMapping, err);
            try std.testing.expect(!case[2]);
            continue;
        };
        defer project.deinit();
        try std.testing.expect(case[2]);
    }
}

test "project stale handles survive allocator address reuse without aliasing" {
    var storage: [262144]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    var first = try init(allocator.allocator(), &.{.{ .name = "one", .bytes = "const x = 1;" }}, &.{}, .{});
    const stale = first.handle(try first.fileAt(0));
    first.deinit();
    allocator.reset();
    var replacement = try init(allocator.allocator(), &.{.{ .name = "two", .bytes = "const x = 2;" }}, &.{}, .{});
    defer replacement.deinit();
    try std.testing.expectError(error.InvalidHandle, replacement.source(stale));
}

test "a ZON input is read as ZON, and the same bytes as Zig are another file" {
    var store: Store = .init(std.testing.allocator);
    defer store.deinit();
    const bytes = ".{ .a = 1 }";
    var project = try init(std.testing.allocator, &.{ .{ .name = "a.zon", .bytes = bytes, .kind = .zon }, .{ .name = "a.zig", .bytes = bytes } }, &.{}, .{ .store = &store });
    defer project.deinit();
    try std.testing.expect(project.sources[0].file != project.sources[1].file);
    try std.testing.expectEqual(File.Status.parsed, project.sources[0].file.status);
    try std.testing.expectEqual(null, project.sources[0].file.zir);
    try std.testing.expectEqual(0, project.sources[0].model.declarations.len);
    try std.testing.expectEqual(File.Status.invalid_lowering, project.sources[1].file.status);
    // Read again as ZON: the store's entry.
    var again = try init(std.testing.allocator, &.{.{ .name = "b.zon", .bytes = bytes, .kind = .zon }}, &.{}, .{ .store = &store });
    defer again.deinit();
    try std.testing.expectEqual(project.sources[0].file, again.sources[0].file);
}

test "a project over a base reads what the base holds from it and leaves the base as it was" {
    var base: Store = .init(std.testing.allocator);
    defer base.deinit();
    const held = "const a = 1;";
    var first = try init(std.testing.allocator, &.{.{ .name = "a.zig", .bytes = held }}, &.{}, .{ .store = &base });
    first.deinit();
    try std.testing.expectEqual(1, base.entries.count());
    var project = try init(std.testing.allocator, &.{ .{ .name = "a.zig", .bytes = held }, .{ .name = "b.zig", .bytes = "const b = 2;" } }, &.{}, .{ .base = &base });
    defer project.deinit();
    // The held file is the base's own; the other is the project's, and the base holds no more.
    try std.testing.expectEqual(&base.entries.get(std.hash.Wyhash.hash(0, held)).?.items[0].file, project.sources[0].file);
    try std.testing.expect(project.sources[1].file != project.sources[0].file);
    try std.testing.expectEqual(1, base.entries.count());
}
