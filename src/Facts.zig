//! Conservative declaration and shape facts over the frozen AST/ZIR project.
//! Unknown comptime and cyclic aliases remain unknown; no spelling guesses.
const std = @import("std");
const aegis = @import("aegis");
const Project = @import("Project.zig");
const Model = @import("Model.zig");
const Constructs = @import("Constructs.zig");
const Ast = std.zig.Ast;
const Facts = @This();

project: *const Project,
/// An arena's: nothing Facts makes is freed one by one, and a memo replaced once the analysis
/// is built (`dropMemos`) is left to it, never freed while a query up the stack may hold it.
gpa: std.mem.Allocator,
/// The library the analyses know by its declarations (aegis): its package's own files, like
/// std's, are not the program's (`program`), under whatever name a program imports it. Only
/// files the caller states are that package's: a module republishing it stays the program's.
known: ?Package = null,
cache: std.AutoHashMapUnmanaged(Settled, Value) = .empty,
/// What a node gives in a reading (`resolveIn`), by the reading's address and the node.
bound: std.AutoHashMapUnmanaged(Bound, Value) = .empty,
/// Each condition's truth on a reading (`comptimeTruth`), by the interned reading (`keptReading`)
/// and the comptime conditions settled around it.
truths: std.AutoHashMapUnmanaged(TruthKey, ?bool) = .empty,
/// The conditions `comptimeTruth` is reading: one asked again inside its own reading is unknown.
truths_open: std.AutoHashMapUnmanaged(TruthKey, void) = .empty,
/// How many `callTruth`s are being read, one inside another.
truth_calls: u8 = 0,
/// Each reading made (`keptReading`), by its function, outer reading and depth.
readings: std.AutoHashMapUnmanaged(ReadingKey, std.ArrayList(*const Env)) = .empty,
active: std.AutoHashMapUnmanaged(Settled, void) = .empty,
/// The sets of comptime `bool` parameters' values that the paths read so far settle, each once.
settled: std.ArrayList(Assumptions) = .empty,
/// The set in force: what the path to the node being read settles; null for none. A value is
/// read as Zig analyses the node, in the instantiations where its path is taken.
assumed: ?Assumptions.Id = null,
/// What each generic function copies of its parameters' values, found once (`parameterCopies`).
copies: ?std.AutoHashMapUnmanaged(Decl, []const ParameterCopy) = null,
/// The names those functions are declared under, for a quick look before a callee is resolved:
/// what the functions so named do with the values given (`copiesBy`).
copier_names: std.StringHashMapUnmanaged(Copies) = .empty,
/// The places the copies `directCopies` finds in a value chosen or wrapped read, each with
/// its copy's declaration: a copy its bindings decide (`boundAtBinding`).
bound_places: std.AutoHashMapUnmanaged(struct { site: Key, place: Ast.Node.Index }, Decl) = .empty,
/// The builtins and `raw` calls `scalarCasts` finds, each with its function: casts each
/// binding decides (`castAtBinding`).
cast_sites: std.AutoHashMapUnmanaged(Key, Decl) = .empty,
/// Whether a file declares any `comptime` parameter of type `bool`, found per file once.
conditional_files: std.AutoHashMapUnmanaged(Project.FileId, bool) = .empty,
publications: std.AutoHashMapUnmanaged(usize, *const Publication) = .empty,
/// Each module's roots, by the address of its members.
module_roots: std.AutoHashMapUnmanaged(usize, []const Project.FileId) = .empty,
templates: std.AutoHashMapUnmanaged(Decl, ?Value) = .empty,
/// What each declaration known only as the program compiles reads as with each call's
/// bindings, found once (`atBindings`).
at_bindings: std.AutoHashMapUnmanaged(Decl, ?[]const Value) = .empty,
/// The values a function's own `return`s give, by function, found once (`ownReturns`).
type_returns: std.AutoHashMapUnmanaged(Decl, []const Ast.Node.Index) = .empty,
/// What each generic parameter binds when the project's own calls are the only ones: the
/// union of their arguments, or null when the function is reachable from outside or taken
/// other than by a call.
callers: std.AutoHashMapUnmanaged(Decl, ?Value) = .empty,
/// The names some container in the project declares as `comptime` fields, found once.
comptime_fields: ?std.StringHashMapUnmanaged(void) = null,
/// The declarations the program dereferences (`p.*`), found per file once.
dereferences: std.AutoHashMapUnmanaged(Decl, void) = .empty,
dereferences_found: std.AutoHashMapUnmanaged(Project.FileId, void) = .empty,
/// Per-run state rules keep across files, by the key they name it with (`memo`).
memos: std.AutoHashMapUnmanaged(usize, *anyopaque) = .empty,
/// The memos whose type declares `lasting`, which `forget` keeps: what each holds was read on
/// a budget of its own (`enter`) with nothing built short, or marks that it was not.
lasting: std.AutoHashMapUnmanaged(usize, *anyopaque) = .empty,
/// Whether a query answered unknown(budget) for want of budget, or past the depth of resolutions
/// in progress, since this Facts was made or last forgot (`forget`): what was built meanwhile
/// may have been built short of it. A walk's own step or depth limit does not set it: it answers
/// the same whoever asks.
short: bool = false,
/// Every member access in the program's files, by the member's name, found once (`memberUses`).
member_uses: ?std.StringHashMapUnmanaged(std.ArrayList(Key)) = null,
/// For each field that holds a function pointer, the functions the program stores in it
/// (`storedFunctions`), or null where a store may not be seen; and those being read.
stored: std.AutoHashMapUnmanaged(Decl, ?Value) = .empty,
storing: std.AutoHashMapUnmanaged(Decl, void) = .empty,
/// Per file, whether every `@import` it makes names a file the program holds (`importsRead`);
/// and per file, the files that may share a compilation with it (`compiledWith`).
imports_read: std.AutoHashMapUnmanaged(Project.FileId, bool) = .empty,
compiled_with: std.AutoHashMapUnmanaged(Project.FileId, Files) = .empty,
/// What a compilation of the program analyzes (`analysis`): per file, the parts Zig analyzes
/// as one; the functions and container-level constants by name; and the budget of resolutions
/// that reading spends, its own as a fact of the whole run.
file_parts: std.AutoHashMapUnmanaged(Project.FileId, *const FileParts) = .empty,
remaining: usize = 100_000,
/// Whether this Facts is the one building the analysis (`analysis`): it reads each declaration
/// as one a compilation may analyze, in any reading.
building_analysis: bool = false,
/// How many answers were given wider than the analysis gives once built (`building_analysis`):
/// what one is read on, whatever reads it while the count grows, is not memoized.
wide: usize = 0,
/// How many times a query met one still in progress and answered unknown for it: a resolution
/// in progress or past its depth, a field's stores being read. An unknown read meanwhile is
/// provisional: the core's one signal for it, which every memo that keeps an unknown checks
/// (snapshot before the read, keep the unknown only where it did not move), as `comptimeTruth` does.
open_met: usize = 0,
/// The analysis being built (`analysis`): a store of a function-pointer field counts once the
/// walk reaches its part (`storeCounts`).
walk: ?*Analysis = null,
/// The memos (`memo`) handed out while the analysis is built, made then or before: each is
/// replaced once it is built (`dropMemos`).
walked: std.AutoHashMapUnmanaged(usize, void) = .empty,
/// Summaries' build mode (designs/glint-summaries.md, step 4): this Facts reads a unit (std, a
/// dependency) for every program that may import it, never for the one it is given. A field,
/// and a public container-level `var`, may be written by code the unit does not hold: each
/// query of its writes also meets one site of kind `open` (`accesses.Each`).
open_world: bool = false,
/// std's size summaries answered by std's open-world records (`Taint.OpenUnit`), as a lint that
/// loads them reads them: what the open world leaves undecided, measured against the live run.
read_records: bool = false,
/// Summaries' cross-check (`Summary.check`): set, each record a query builds is written and
/// read back, and a record that reads back other than the live answer stops the run.
check_records: ?*const RecordCheck = null,

/// What reads a record back for the cross-check (`check_records`), one for each kind of record.
pub const RecordCheck = struct {
    accesses: *const fn (*Facts, Project.FileId, *const accesses.File, []const u8) ResolveError!void,
    copies: *const fn (*Facts, *const std.AutoHashMapUnmanaged(Decl, []const ParameterCopy)) ResolveError!void,
};

pub const Key = struct { file: Project.FileId, node: Ast.Node.Index };
/// A node read under a set of settled comptime conditions (`assumed`).
const Settled = struct { key: Key, assumed: ?Assumptions.Id };
const Bound = struct { env: *const Env, settled: Settled };
const TruthKey = struct { key: Key, env: ?*const Env, assumed: ?Assumptions.Id };
/// A set of settled assumptions, held once in `settled`.
const Assumptions = struct {
    held: []const Assumption,

    /// A set of `settled`, made only as it is appended or by counting them.
    const Id = enum(u32) { _ };
};
/// A `comptime` parameter's value on a path: a `bool`'s inside `if (wrapped)`'s branches or
/// after `if (wrapped) return ...;`, an enum's inside a `switch` prong naming one tag. Zig
/// analyses a branch of a comptime-known condition only in the instantiations that take it, so
/// what the path settles holds for everything read there.
pub const Assumption = struct {
    parameter: Decl,
    value: Known,

    fn eql(a: Assumption, b: Assumption) bool {
        if (!std.meta.eql(a.parameter, b.parameter) or std.meta.activeTag(a.value) != std.meta.activeTag(b.value)) return false;
        return switch (a.value) {
            .boolean => |value| value == b.value.boolean,
            .tag => |name| std.mem.eql(u8, name, b.value.tag),
        };
    }
};
pub const Known = union(enum) {
    boolean: bool,
    /// The enum literal's name, as written.
    tag: []const u8,
};
pub const Decl = struct { file: Project.FileId, index: Model.Declaration.Id };
pub const Container = struct {
    file: Project.FileId,
    scope: Model.Scope.Id,
    symbolic: bool = false,
    /// For a container a type function made: the call that made it, whose arguments its
    /// methods' results may name. Identity is `file` and `scope` alone.
    made_by: ?*const Made = null,
};
pub const Made = struct {
    function: Decl,
    file: Project.FileId,
    call: Ast.Node.Index,
    env: ?*const Env = null,
    assumed: ?Assumptions.Id = null,
    /// For a type function that returns another's call (`Owned(T, f)` returning
    /// `Owner(T, false, f)`): the call that made the outer one, whose bindings this call's
    /// arguments are read with.
    via: ?*const Made = null,
    /// For a container a generic declares in its own body (`const Instance = struct { fn_args:
    /// Args }` in std's `Thread.spawn`), read in one reading of it: that reading, whose bindings
    /// its names read (`madeEnv`). `call` is then the container's own node.
    reading: ?*const Env = null,
    /// The reading that binds the type function to this call's arguments (`madeEnv`): what
    /// the made type is, as Zig makes one type per function and comptime arguments, wherever
    /// the call is written (`sameMaking`).
    bound: ?*const Env = null,
};
/// One call of a generic function being read: its parameters bound to the call's arguments,
/// in order (a method's receiver first). A type it returns, or a result type written in terms
/// of them, is read with these bindings.
/// One is made where it is kept for the run and never changed once read: what a node reads in
/// it is memoized by where it is (`resolveIn`).
pub const Env = struct {
    function: Decl,
    args: []const Value,
    /// How many calls deep the chain that first made it is: a reader of chains bounds it
    /// (Taint's `readingAt`). Not part of what the reading is (`keptReading`).
    depth: usize,
    /// How many type functions' evaluations it is made inside (`evaluateCall`), bounded at 8
    /// so a type function that calls itself with ever new arguments ends; a call of a chain
    /// (`bind`) adds none, however deep.
    nested: usize = 0,
    /// Each argument's value as a condition, where it is a comptime-known `bool`.
    truths: []const ?bool = &.{},
    /// The reading whose function encloses this one, which binds the names it reads beyond
    /// its own parameters: a type function declared in a type function's container (std's
    /// `FieldIterator(V)` in a hash map) reads that one's parameters as it binds them. None
    /// where no reading made it encloses the function (`enclosingReading`): a caller that
    /// does not enclose it binds nothing it reads.
    outer: ?*const Env = null,
    /// What each argument spells where it is written (`spelledIn`), in order with `args`
    /// (none for a receiver or one that spells nothing): what a name a type function is given
    /// (`items(.tag)`, `@tagName(field)`) reads, or a number written as a literal (`Pick(1)`).
    spelled: []const ?Spelled = &.{},
    /// Whether each argument's expression is a value (`valueIn` in the reading the call is
    /// in), in order with `args`: Zig makes one instance of a function handed a type and
    /// another handed a value, so it is part of the instantiation. False where the site has no
    /// expression for the argument, or it is not known to be a value.
    values: []const bool = &.{},
};
/// What an argument spells: a name (`nameIn`), or a number written as a literal.
pub const Spelled = union(enum) { name: []const u8, number: usize };
/// A type seen through `@typeInfo`, and how far into its information a chain of fields has
/// gone: `.pointer.child`, `.optional.child`, `.array.child`, `.error_union.payload`,
/// `.@"fn".return_type` and `.@"fn".param_types[i]`. `part` is any other part of the
/// information (`.@"struct".fields`, a field's `name`): a `std.builtin.Type` value whose own
/// members are not followed. A type that does not resolve still has information: what it
/// describes stays unknown, never what the information is.
/// Type information read off a type (`of`) at a part of it: the whole (`info`), a kind's own
/// (`pointer`, ...), a pointer's size (`size`), a function's parameters, any other part.
pub const Reflected = struct { of: *const Value, at: enum { info, pointer, size, optional, array, error_union, function, params, structure, tagged, enumeration, part } };
/// A library's declarations in this project, found through its modules' roots. Roles are the
/// caller's enum values; the resolver never interprets them.
pub const Publication = struct {
    entries: []const Entry,
    /// Required members that did not resolve: drift or a missing module mapping, never silence.
    gaps: []const Gap,
    /// The library's own files. A library with a package (aegis's) has the files of that
    /// identity: a file publishing its API, a program's re-export or a copy without its
    /// manifest, stays the program's, whatever it turns on. One without is known by its import
    /// alone: every file its roots reach, std and builtin aside.
    files: []const Project.FileId,
};
pub const Entry = struct { role: u32, target: Target };
pub const Target = union(enum) { function: Decl, container: Container };
/// A required member `module`'s root `root` does not publish: reported where a file imports
/// that root, under whatever name.
pub const Gap = struct { module: []const u8, path: []const u8, why: Unknown, root: Project.FileId };
/// Why a value is unknown. `absent`: it comes from a module the build does not have for this
/// file (Project.Input.absent), or it is a parameter no function of a reflected choice has
/// (`param_types[6]` of a table whose functions take at most six), so the code that needs it
/// is not compiled in this build.
/// `generic`: it depends on a type or `anytype` parameter that calls from outside the
/// project's reading bind (a consumer's, or a use other than a call), so each binding decides
/// it where it is made; what is read of it (its type information, its parts) stays so.
/// `zig_own`: it is Zig's own per-build file: the compiler's `builtin` (the target, the
/// optimize mode, the build's options) any file imports, or the `root` std reads
/// (`root.std_options`), which no library's reading binds; a type or value the compiler
/// computes for each build, holding no store and none of the program's types.
/// Whether something is so: yes, no, or unknown and why.
pub const Is = union(enum) { yes, no, unknown: Unknown };
pub const Unknown = enum { invalid_front_end, unresolved, missing_mapping, computed_import, comptime_dependent, cycle, budget, unsupported, absent, generic, zig_own };
/// The declaration an expression names (`definition`, `reflected`, `origin`): one known, none
/// (no reference at all: a literal, a call, a member its holder does not declare, a primitive),
/// or unknown and why (a holder that does not resolve, a choice of holders, a computed name, a
/// cycle). Unknown is never none: a rule reads it as undecided.
pub const Named = union(enum) {
    decl: Decl,
    none,
    unknown: Unknown,

    pub fn of(found: ?Decl) Named {
        return if (found) |decl| .{ .decl = decl } else .none;
    }
    /// The declaration, or null for none and for unknown alike, as every caller read it before
    /// `Named`: each use drops an unknown. Every use is to become a switch that makes `.unknown`
    /// undecided where it decides; `orNull_test` counts them, the count only falls, and at none
    /// this goes.
    pub fn orNull(self: Named) ?Decl {
        return switch (self) {
            .decl => |decl| decl,
            .none, .unknown => null,
        };
    }
};
pub const Value = union(enum) {
    unknown: Unknown,
    primitive: []const u8,
    container: Container,
    instance: Container,
    function: Decl,
    /// A pointer to its child, of the size its type gives (`Pointer`). A slice or many-item
    /// pointer is a `pointer` to its element, as Zig indexes both the same way.
    pointer: Pointer,
    /// An array of the element: `[N]T`.
    array: *const Value,
    optional: *const Value,
    error_union: *const Value,
    error_set,
    scalar,
    /// One of several, each known: a `switch` or `if` whose branches differ, such as a type
    /// chosen per target. Never holds an unknown or another `alternatives`.
    alternatives: []const Value,
    reflected: Reflected,
    /// A struct literal with no type of its own where nothing gives it one (`.{ .a = x }` as a
    /// block's value or an `anytype` argument): an anonymous struct whose fields are the ones
    /// the literal names, with the values it gives them.
    literal: Key,
    /// A type Zig builds from a list of field types (`@Struct`, `@Union`, `@Tuple`), or a
    /// value of one: it holds what those types do, one or a choice among them. Its fields'
    /// names are computed as the program compiles.
    reified: Reified,
    /// A function type written in place (`fn (?*anyopaque, Io.Dir) void`, a vtable field's
    /// behind `*const`): its parameters' and result's types, as a declared function's are.
    fn_type: Key,

    pub fn known(self: Value) bool {
        return self != .unknown;
    }
};
/// A pointer to `child`: to one item (`*T`), to many (`[*]T`), a slice (`[]T`) or a C pointer,
/// as its type says (`std.builtin.Type.Pointer.Size`); null where what makes it does not say
/// (a slicing: bounds known as the program compiles make a pointer to an array, others a
/// slice). Two pointers are the same type only of the same size.
pub const Pointer = struct { child: *const Value, size: ?Size };
pub const Size = std.builtin.Type.Pointer.Size;
pub const ResolveError = Model.InitError;
/// A type built from its fields' types, the type itself or a value of it as `container` and
/// `instance` are.
pub const Reified = struct { fields: *const Value, value: bool = false };

/// A pointer to `child` of `size` (`Pointer`).
pub fn pointerTo(self: *Facts, child: Value, size: ?Size) ResolveError!Value {
    return .{ .pointer = .{ .child = try self.boxed(child), .size = size } };
}

/// The pointer size `node` names (`@Pointer`'s first argument): an enum literal (`.slice`), or
/// a pointer's own read off its type information (`info.size`). Null where it names none known.
fn sizeNamed(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Size {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(node) == .enum_literal) return std.meta.stringToEnum(Size, try self.memberName(tree.tokenSlice(tree.nodeMainToken(node))));
    const value = try self.resolveIn(env, file, node);
    if (value != .reflected or value.reflected.at != .size) return null;
    return if (value.reflected.of.* == .pointer) value.reflected.of.pointer.size else null;
}

/// What a value of a type built from its fields' types holds: a value of each of them.
pub fn reifiedParts(self: *Facts, built: Reified) ResolveError!Value {
    return self.instance(built.fields.*);
}

pub fn deinit(self: *Facts) void {
    self.cache.deinit(self.gpa);
    self.bound.deinit(self.gpa);
    self.readings.deinit(self.gpa);
    self.active.deinit(self.gpa);
    self.truths_open.deinit(self.gpa);
    self.settled.deinit(self.gpa);
    if (self.copies) |*found| found.deinit(self.gpa);
    self.copier_names.deinit(self.gpa);
    self.bound_places.deinit(self.gpa);
    self.cast_sites.deinit(self.gpa);
    self.conditional_files.deinit(self.gpa);
    self.publications.deinit(self.gpa);
    self.module_roots.deinit(self.gpa);
    self.templates.deinit(self.gpa);
    self.type_returns.deinit(self.gpa);
    self.at_bindings.deinit(self.gpa);
    self.callers.deinit(self.gpa);
    if (self.comptime_fields) |*names| names.deinit(self.gpa);
    self.dereferences.deinit(self.gpa);
    self.dereferences_found.deinit(self.gpa);
    self.* = undefined;
}

/// A package by its identity: the name and fingerprint its `build.zig.zon` gives.
pub const Package = @import("Library.zig").Package;

/// Whether `file` is one of the known library's own (`known`): its package is the library's,
/// as the caller states it. A file whose package the caller does not state is not.
pub fn knownFile(self: *const Facts, file: Project.FileId) bool {
    return self.ofPackage(file, self.known orelse return false);
}

/// Whether the caller states `file` to be of `package`, by name and fingerprint.
fn ofPackage(self: *const Facts, file: Project.FileId, package: Package) bool {
    const input = self.project.at(file).input;
    return input.fingerprint == package.fingerprint and std.mem.eql(u8, input.package, package.name);
}

/// The files a module's root is: each file a file outside the known library imports by the
/// module's name, or the library's own file under any name, where it is the library's own or
/// its package is not stated, or where it
/// publishes any member the module requires or does not parse (the members it lacks are
/// gaps the run reports); and each, under any name and of any package, that publishes every
/// member the module requires: the library's own file, its sources vendored into another
/// package's tree, a manifest that names nothing, a module republishing it. Which files leave
/// the program is the library's identity alone (`outside`): a module republishing it stays
/// the program's. A file whose members do not resolve far enough to tell is a root, as one
/// that does not parse is: the members it may lack are gaps the run reports, never a module
/// it is not. Found once per run.
pub fn moduleRoots(self: *Facts, module: anytype) ResolveError![]const Project.FileId {
    const key = @intFromPtr(module.members.ptr);
    if (self.module_roots.get(key)) |found| return found;
    var required = false;
    for (module.members) |listed| required = required or listed.required;
    var roots: std.ArrayList(Project.FileId) = .empty;
    var other: FileSet = .empty;
    for (self.project.imports) |mapping| {
        if (std.mem.findScalar(Project.FileId, roots.items, mapping.target) != null) continue;
        // A library's modules are the program's: a build script's import of the library's name
        // is the library's build script, as the build runner names it.
        if (!mapping.in.inProgram()) continue;
        // The library's own import of its parts is no program's import of a module.
        if (self.knownFile(mapping.from) and self.knownFile(mapping.target)) continue;
        // The library's own file is it under any name (a second revision imported as
        // `aegis_old`): by identity, as its files leave the program. Under another module's
        // name it is that module where it publishes some of it (aegis's root is not
        // `aegis.int`, whose members it publishes under `int`).
        const spelled = std.mem.eql(u8, mapping.spelling, module.name);
        const named = spelled or self.knownFile(mapping.target);
        const stated = !self.knownFile(mapping.target) and self.project.at(mapping.target).input.fingerprint != null;
        const parsed = self.project.at(mapping.target).file.status == .parsed;
        if (!spelled and named and parsed and try self.publishesAny(module, mapping.target) == .no) continue;
        if (!named or stated) {
            // Under its name, a module publishing some of it is it with members missing, and
            // one that does not parse may be; publishing none, it is another.
            if (!(named and (!parsed or try self.publishesAny(module, mapping.target) != .no))) {
                if (other.contains(@backingInt(mapping.target))) continue;
                if (!(required and parsed and try self.publishes(module, mapping.target) != .no)) {
                    try other.put(self.gpa, @backingInt(mapping.target), {});
                    continue;
                }
            }
        }
        try roots.append(self.gpa, mapping.target);
    }
    try self.module_roots.put(self.gpa, key, roots.items);
    return roots.items;
}

/// Finds what `library` publishes: each module's roots (`moduleRoots`), and each member the
/// declaration its path names from a root. Found once per run and shared by every rule.
pub fn publication(self: *Facts, library: anytype) ResolveError!*const Publication {
    const key = @intFromPtr(library.modules.ptr);
    if (self.publications.get(key)) |found| return found;
    var entries: std.ArrayList(Entry) = .empty;
    var gaps: std.ArrayList(Gap) = .empty;
    var reached: FileSet = .empty;
    for (library.modules) |module| {
        for (try self.moduleRoots(module)) |root| {
            try reached.put(self.gpa, @backingInt(root), {});
            for (module.members) |listed| switch (try self.published(root, listed.path)) {
                .found => |target| {
                    const role_value: u32 = @intCast(@backingInt(listed.role));
                    try entries.append(self.gpa, .{ .role = role_value, .target = target });
                    // The container a type function returns is also its type: instances declared with it are the role's,
                    // each container it may return where it chooses one by a comptime option (aegis 0.3's
                    // `SlotPool(T, Tag, options)`: `Keyed` or `Indexed`).
                    if (target == .function) if (try self.template(target.function)) |returned| for (try returnedContainers(self.gpa, returned)) |made| {
                        try entries.append(self.gpa, .{ .role = role_value, .target = .{ .container = .{ .file = made.file, .scope = made.scope } } });
                    };
                },
                .absent => if (listed.required) try gaps.append(self.gpa, .{ .module = module.name, .path = listed.path, .why = .unresolved, .root = root }),
                .unknown => |why| if (listed.required) try gaps.append(self.gpa, .{ .module = module.name, .path = listed.path, .why = why, .root = root }),
            };
        }
    }
    var files: std.ArrayList(Project.FileId) = .empty;
    if (library.package) |package| {
        for (self.project.sources) |*source| if (self.ofPackage(source.id, package)) try files.append(self.gpa, source.id);
    } else {
        try self.reach(&reached, .library);
        var each = reached.keyIterator();
        while (each.next()) |file| try files.append(self.gpa, @fromBackingInt(file.*));
    }
    const result = try self.gpa.create(Publication);
    result.* = .{ .entries = entries.items, .gaps = gaps.items, .files = files.items };
    try self.publications.put(self.gpa, key, result);
    return result;
}

/// The containers a type function's template is (`template`): the one it returns, or each it
/// may choose by a comptime option (`if (options.generation) |G| Keyed(T, Tag, G) else
/// Indexed(T, Tag)`) where every choice is one. None where it is anything else, a choice that is
/// not a container among them: what its instances are is then not known from it.
pub fn returnedContainers(gpa: std.mem.Allocator, made: Value) error{OutOfMemory}![]const Container {
    switch (made) {
        .container, .instance => |one| {
            const found = try gpa.alloc(Container, 1);
            found[0] = one;
            return found;
        },
        .alternatives => |choices| {
            const found = try gpa.alloc(Container, choices.len);
            for (choices, found) |choice, *each| each.* = switch (choice) {
                .container, .instance => |one| one,
                else => return &.{},
            };
            return found;
        },
        else => return &.{},
    }
}

/// A declaration literal called (`.init(...)`): the function its result location's container
/// declares (`literalDeclaration`). Any other enum literal's meaning is its result location's,
/// which is not known here.
fn declarationLiteral(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const parent = self.project.at(file).model.parentOf(node) orelse return .{ .unknown = .comptime_dependent };
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, parent) orelse return .{ .unknown = .comptime_dependent };
    if (call.ast.fn_expr != node) return .{ .unknown = .comptime_dependent };
    return switch (try self.literalDeclaration(file, node, try self.memberName(tree.tokenSlice(tree.nodeMainToken(node))))) {
        .decl => |found| self.declaration(found),
        .none => .{ .unknown = .unsupported },
        .unknown => .{ .unknown = .comptime_dependent },
    };
}

/// Whether a file publishes a module's members: `unknown` where one does not resolve far enough
/// to tell and none decides the answer.
pub const Publishes = enum { yes, no, unknown };

/// Whether the file `root` publishes every member `module` requires: that module, not another
/// of its name. One member it lacks says no; one that does not resolve, with none lacking, is
/// unknown.
pub fn publishes(self: *Facts, module: anytype, root: Project.FileId) ResolveError!Publishes {
    var answer: Publishes = .yes;
    for (module.members) |listed| if (listed.required) switch (try self.published(root, listed.path)) {
        .found => {},
        .absent => return .no,
        .unknown => answer = .unknown,
    };
    return answer;
}

/// Whether the file `root` publishes any member `module` requires. One it has says yes; one
/// that does not resolve, with none found, is unknown.
pub fn publishesAny(self: *Facts, module: anytype, root: Project.FileId) ResolveError!Publishes {
    var answer: Publishes = .no;
    for (module.members) |listed| if (listed.required) switch (try self.published(root, listed.path)) {
        .found => return .yes,
        .absent => {},
        .unknown => answer = .unknown,
    };
    return answer;
}

/// A member a root publishes; one it does not (no public declaration of that name on the
/// path); or why the path does not resolve far enough to tell.
const Found = union(enum) { found: Target, absent, unknown: Unknown };
/// Walks public namespaces from a module root, the way a program names the declaration.
fn published(self: *Facts, root: Project.FileId, path: []const u8) ResolveError!Found {
    var current: Value = .{ .container = self.rootOf(root) };
    var names = std.mem.splitScalar(u8, path, '.');
    while (names.next()) |name| {
        const container = switch (current) {
            .container, .instance => |c| c,
            // A member of a type function's container, as `Budget.Reservation` names the
            // reservation every budget declares. A function whose container this does not
            // find may still make one.
            .function => |function| switch ((try self.template(function)) orelse return .{ .unknown = .unsupported }) {
                .container, .instance => |c| c,
                else => return .{ .unknown = .unsupported },
            },
            // A type that declares nothing, or a value of one, names no member.
            .primitive, .scalar, .error_set, .pointer, .array, .optional, .error_union => return .absent,
            .unknown => |why| return .{ .unknown = why },
            .alternatives, .reflected, .literal, .reified, .fn_type => return .{ .unknown = .unsupported },
        };
        const decl = self.member(container, name) orelse return .absent;
        if (!self.project.at(decl.file).model.declarations[@backingInt(decl.index)].public) return .absent;
        current = try self.declaration(decl);
    }
    return switch (current) {
        .function => |decl| .{ .found = .{ .function = decl } },
        .container => |c| .{ .found = .{ .container = .{ .file = c.file, .scope = c.scope } } },
        .unknown => |why| .{ .unknown = why },
        // A declaration of the name the library's is, of a kind no role names: there, but
        // not what the library publishes there.
        else => .{ .unknown = .unsupported },
    };
}

/// The role `library` publishes for a function declaration, or a type or instance of a
/// published container, seen through pointers, optionals and error unions.
pub fn role(self: *Facts, library: anytype, value: Value) ResolveError!?@TypeOf(library).Role {
    const Role = @TypeOf(library).Role;
    const found = try self.publication(library);
    var current = value;
    while (true) switch (current) {
        .pointer => |inner| current = inner.child.*,
        .array, .optional, .error_union => |inner| current = inner.*,
        .function => |decl| {
            for (found.entries) |entry| if (entry.target == .function and std.meta.eql(entry.target.function, decl)) return @as(Role, @fromBackingInt(@intCast(entry.role)));
            return null;
        },
        .container, .instance => |c| {
            for (found.entries) |entry| if (entry.target == .container and entry.target.container.file == c.file and entry.target.container.scope == c.scope) return @as(Role, @fromBackingInt(@intCast(entry.role)));
            return null;
        },
        else => return null,
    };
}

/// What was built since a query answered unknown(budget) for want of budget (`short`), dropped:
/// its memos and indexes may have been built short of it, which would answer a later query as
/// if complete (C1). What `resolve` keeps stays: it keeps only what was read with budget left,
/// and the sets of assumptions its keys name; so does what `resolveIn` keeps, by readings that
/// are never freed; and each `lasting` memo: a unit read on a budget of its own that read
/// nothing built short (the program's solve, `Taint.get`), or the mark that it ran short. What
/// one keeps is the run's (`gpa`), never a part of an index dropped here.
pub fn forget(self: *Facts) void {
    var fresh: Facts = .{ .project = self.project, .gpa = self.gpa, .known = self.known, .remaining = self.remaining, .cache = self.cache, .bound = self.bound, .readings = self.readings, .settled = self.settled, .lasting = self.lasting };
    self.cache = .empty;
    self.bound = .empty;
    self.readings = .empty;
    self.settled = .empty;
    self.lasting = .empty;
    self.deinit();
    fresh.active = .empty;
    self.* = fresh;
}

/// A query's answer where the budget is spent: unknown(budget), and this Facts is `short`.
fn spent(self: *Facts) Value {
    _ = self.budgetSpent();
    return .{ .unknown = .budget };
}

/// Whether the budget is spent: what a query read before may have been cut short of it, which
/// it answers as unknown(budget), and this Facts is then `short`.
pub fn budgetSpent(self: *Facts) bool {
    if (self.remaining != 0) return false;
    self.short = true;
    return true;
}

/// What the asker of a unit of solving had when the unit started (`enter`), given back when it
/// ends (`leave`): its budget and whether it was `short`.
pub const Asker = struct { remaining: usize, short: bool };

/// Starts a unit of solving on a budget of its own, `budget` resolutions: the asker's budget is
/// neither charged for it nor given to it (designs/glint-summaries.md, "One budget model"). The
/// file's analysis, each of its readings, std's closings and the program's solve are each one.
/// Each ends with `leave`, on an error's way out too.
pub fn enter(self: *Facts, budget: usize) Asker {
    const asker: Asker = .{ .remaining = self.remaining, .short = self.short };
    self.remaining = budget;
    self.short = false;
    return asker;
}

/// Ends the unit `enter` started, the asker's budget its own again. Returns whether the unit
/// ran short: a query in it answered unknown(budget) for want of budget. This Facts is then
/// `short` where the asker was or the unit ran short.
pub fn leave(self: *Facts, asker: Asker) bool {
    const short = self.short;
    self.remaining = asker.remaining;
    self.short = asker.short or short;
    return short;
}

pub fn resolve(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    if (self.project.at(file).file.status != .parsed) return .{ .unknown = .invalid_front_end };
    const key: Settled = .{ .key = .{ .file = file, .node = node }, .assumed = self.assumed };
    if (self.cache.get(key)) |value| return value;
    if (self.active.count() >= 128) {
        // How deep the asker is decides it, not the node: what is built over it may be built
        // short, as past the budget (`short`).
        self.open_met += 1;
        self.short = true;
        return .{ .unknown = .budget };
    }
    if (self.remaining == 0) return self.spent();
    self.remaining -= 1;
    if (self.active.contains(key)) {
        self.open_met += 1;
        return .{ .unknown = .cycle };
    }
    try self.active.put(self.gpa, key, {});
    defer _ = self.active.remove(key);
    const outer = self.assumed;
    defer self.assumed = outer;
    self.assumed = try self.settle(file, node, outer);
    const wide = self.wide;
    const value = try self.resolveInner(file, node);
    // Read with none left, a part of it may have come back unknown(budget): it is not kept.
    if (self.remaining != 0 and !self.wideSince(wide)) try self.cache.put(self.gpa, key, value);
    return value;
}

/// The set of assumptions in force at `node`: `outer` and what the path to `node` settles. A
/// path `outer` contradicts is not taken where `outer` holds; it keeps `outer`.
fn settle(self: *Facts, file: Project.FileId, node: Ast.Node.Index, outer: ?Assumptions.Id) ResolveError!?Assumptions.Id {
    if (!try self.hasConditions(file)) return outer;
    var found: std.ArrayList(Assumption) = .empty;
    try found.appendSlice(self.gpa, self.assumptions(outer));
    const before = found.items.len;
    if (!try self.pathFacts(file, node, &found)) return outer;
    if (found.items.len == before) return outer;
    return try self.intern(found.items);
}

/// Whether the path to `node` contradicts the assumptions in force: code an instantiation
/// that settles them does not analyse.
fn dead(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    if (self.assumed == null or !try self.hasConditions(file)) return false;
    var found: std.ArrayList(Assumption) = .empty;
    try found.appendSlice(self.gpa, self.assumptions(self.assumed));
    return !try self.pathFacts(file, node, &found);
}

fn assumptions(self: *const Facts, set: ?Assumptions.Id) []const Assumption {
    return if (set) |id| self.settled.items[@backingInt(id)].held else &.{};
}

/// The set holding exactly `items`, added if new.
pub fn intern(self: *Facts, items: []const Assumption) ResolveError!Assumptions.Id {
    for (self.settled.items, 0..) |set, index| {
        if (set.held.len != items.len) continue;
        for (items) |item| {
            for (set.held) |held| {
                if (held.eql(item)) break;
            } else break;
        } else return @fromBackingInt(@intCast(index));
    }
    try self.settled.append(self.gpa, .{ .held = try self.gpa.dupe(Assumption, items) });
    return @fromBackingInt(@intCast(self.settled.items.len - 1));
}

/// Adds to `found` what the path from the file's root to `node` settles: the branch of each
/// `if` on a comptime `bool` parameter that holds it, the prong of each `switch` on a comptime
/// enum parameter, and, in each enclosing block, every earlier `if (c) <exit>;` (the rest of
/// the block runs only where `c` is false). False when the path contradicts `found`.
fn pathFacts(self: *Facts, file: Project.FileId, node: Ast.Node.Index, found: *std.ArrayList(Assumption)) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    if (model.node_parents.len == 0) return true;
    var child = node;
    var up = model.parentOf(node);
    while (up) |parent| : ({
        child = parent;
        up = model.parentOf(parent);
    }) {
        if (tree.fullIf(parent)) |whole| if (whole.payload_token == null and whole.error_token == null) {
            if (child == whole.ast.then_expr and !try self.holds(file, whole.ast.cond_expr, true, found)) return false;
            if (whole.ast.else_expr.unwrap() == child and !try self.holds(file, whole.ast.cond_expr, false, found)) return false;
        };
        if (tree.fullSwitchCase(parent)) |case| if (case.ast.target_expr == child) if (model.parentOf(parent)) |at| if (tree.fullSwitch(at)) |whole| {
            if (self.switchParameter(file, whole.ast.condition)) |parameter| if (!try self.prong(tree, whole, case, parameter, found)) return false;
        };
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, parent) orelse continue;
        for (statements) |statement| {
            if (statement == child) break;
            const whole = tree.fullIf(statement) orelse continue;
            if (whole.payload_token != null or whole.error_token != null) continue;
            const then_exits = completesNever(tree, whole.ast.then_expr);
            const else_exits = if (whole.ast.else_expr.unwrap()) |e| completesNever(tree, e) else false;
            if (then_exits == else_exits) continue;
            if (!try self.holds(file, whole.ast.cond_expr, else_exits, found)) return false;
        }
    }
    return true;
}

/// Records that the condition `node` is `value` where it names comptime `bool` parameters
/// (`wrapped`, `!wrapped`, `a and b` true, `a or b` false); other conditions settle nothing.
/// False when `found` already holds the opposite.
fn holds(self: *Facts, file: Project.FileId, node: Ast.Node.Index, value: bool, found: *std.ArrayList(Assumption)) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    switch (conditionOf(tree, node)) {
        .not => |inner| return self.holds(file, inner, !value, found),
        // Each operand is known only when the whole is: `a and b` true, `a or b` false.
        .both => |sides| return !value or (try self.holds(file, sides[0], true, found) and try self.holds(file, sides[1], true, found)),
        .either => |sides| return value or (try self.holds(file, sides[0], false, found) and try self.holds(file, sides[1], false, found)),
        .compare => return true,
        .other => |at| {
            if (tree.nodeTag(at) != .identifier) return true;
            const parameter = self.conditionParameter(file, at) orelse return true;
            for (found.items) |held| if (std.meta.eql(held.parameter, parameter)) return held.value == .boolean and held.value.boolean == value;
            try found.append(self.gpa, .{ .parameter = parameter, .value = .{ .boolean = value } });
            return true;
        },
    }
}

/// Records that a `switch` prong on a comptime parameter is taken: the parameter is the tag the
/// prong's one item names. False when `found` holds a tag the prong does not take: none of its
/// items, or for `else`, one a case names.
fn prong(self: *Facts, tree: *const Ast, whole: Ast.full.Switch, case: Ast.full.SwitchCase, parameter: Decl, found: *std.ArrayList(Assumption)) ResolveError!bool {
    for (found.items) |held| if (std.meta.eql(held.parameter, parameter)) {
        if (held.value != .tag) return true;
        if (case.ast.values.len == 0) {
            for (whole.ast.cases) |other| for (tree.fullSwitchCase(other).?.ast.values) |item| if (namesTag(tree, item, held.value.tag)) return false;
            return true;
        }
        for (case.ast.values) |item| if (namesTag(tree, item, held.value.tag)) return true;
        return false;
    };
    if (case.ast.values.len == 1 and tree.nodeTag(case.ast.values[0]) == .enum_literal) try found.append(self.gpa, .{ .parameter = parameter, .value = .{ .tag = tree.tokenSlice(tree.nodeMainToken(case.ast.values[0])) } });
    return true;
}

fn namesTag(tree: *const Ast, item: Ast.Node.Index, tag: []const u8) bool {
    return tree.nodeTag(item) == .enum_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(item)), tag);
}

/// Whether the function around `node` branches on a comptime `bool` parameter, or switches on a
/// comptime enum one, anywhere in its body: its paths then differ between the instantiations
/// that bind it.
pub fn branchesOnCondition(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    if (!try self.hasConditions(file)) return false;
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var up = model.parentOf(node);
    const function = while (up) |parent| : (up = model.parentOf(parent)) {
        if (tree.nodeTag(parent) == .fn_decl) break parent;
    } else return false;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const branch: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(branch);
        if (at < first or at > last) continue;
        switch (tag) {
            .@"if", .if_simple => if (self.namesCondition(file, tree.fullIf(branch).?.ast.cond_expr, 0)) return true,
            .@"switch", .switch_comma => if (self.switchParameter(file, tree.fullSwitch(branch).?.ast.condition) != null) return true,
            else => {},
        }
    }
    return false;
}

fn namesCondition(self: *const Facts, file: Project.FileId, node: Ast.Node.Index, depth: usize) bool {
    if (depth == 16) return false;
    const tree = &self.project.at(file).file.tree;
    return switch (conditionOf(tree, node)) {
        .not => |inner| self.namesCondition(file, inner, depth + 1),
        .both, .either => |sides| self.namesCondition(file, sides[0], depth + 1) or self.namesCondition(file, sides[1], depth + 1),
        .compare => false,
        .other => |value| tree.nodeTag(value) == .identifier and self.conditionParameter(file, value) != null,
    };
}

/// A local a generic function initialises by copying a value its type parameter at `position`
/// types (`var result = value;` of `value: T`), or its `anytype` parameter at `position`
/// (`var local = args;`), there or in a function it passes the parameter on to (as is, or a
/// part of it its type information gives). Or a local it initialises by calling a function of
/// its type parameter at `position` (`var h = Hash.init(.{});`): what the call gives is the
/// binding's, an owner where the binding is one. What a call passes on may be the parameter
/// itself or a value of it, or something else read from it (what calling it returns, what it
/// points to): then `source` is that expression, read with the binding's arguments through the
/// calls of `path`, each in the function before it, the first in the generic the copy is of.
/// Each route to a source is its own copy, up to `routes`; past them the copy is `crowded`,
/// and a binding of it is not read.
pub const ParameterCopy = struct {
    position: usize,
    site: Key,
    /// `moved`: the parameter itself written once into storage, read nowhere else (`out.* = x`):
    /// what the call gives moves there, a copy where the argument does not move at the call.
    kind: enum { copy, moved, made, cast } = .copy,
    source: ?Key = null,
    path: []const Key = &.{},
    crowded: bool = false,
};

/// How many routes through generics to one source are read for each parameter and copy.
const routes = 4;

/// The copies `function` makes of its generic parameters' values. Found once for every function
/// outside std: a copy where it is written, then through calls that pass a parameter on, until
/// nothing more is found.
pub fn parameterCopies(self: *Facts, function: Decl) ResolveError![]const ParameterCopy {
    if (self.copies == null) try self.findCopies();
    return self.copies.?.get(function) orelse &.{};
}

fn findCopies(self: *Facts) ResolveError!void {
    var found: std.AutoHashMapUnmanaged(Decl, []const ParameterCopy) = .empty;
    self.copies = found;
    const std_files = &(try self.outside()).std_files;
    var functions: std.ArrayList(Decl) = .empty;
    for (self.project.sources) |*source| {
        const file = source.file;
        const model = &source.model;
        const id = source.id;
        if (file.status != .parsed or std_files.contains(@backingInt(id))) continue;
        for (model.declarations, 0..) |d, i| {
            if (d.kind != .function) continue;
            const decl: Decl = .{ .file = id, .index = @fromBackingInt(@intCast(i)) };
            if (self.syntaxOf(id).nodeTag(self.scopeNode(decl)) != .fn_decl) continue;
            if (!self.hasGenericParameter(decl)) continue;
            try functions.append(self.gpa, decl);
            var direct: std.ArrayList(ParameterCopy) = .empty;
            try self.directCopies(decl, &direct);
            if (direct.items.len != 0) try found.put(self.gpa, decl, direct.items);
        }
    }
    // Through calls that pass a parameter on, to a fixed point: a function whose copies grow
    // is read again in each generic that calls it. Copies only grow, each route at most once
    // and at most `routes` routes to a source, so it ends.
    var passes: std.AutoHashMapUnmanaged(Decl, []const Passing) = .empty;
    var callers: std.AutoHashMapUnmanaged(Decl, std.ArrayList(Decl)) = .empty;
    for (functions.items) |decl| {
        const passing = try self.passings(decl);
        try passes.put(self.gpa, decl, passing);
        for (passing) |each| {
            const entry = try callers.getOrPut(self.gpa, each.target);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(self.gpa, decl);
        }
    }
    var queue: std.ArrayList(Decl) = .empty;
    var queued: std.AutoHashMapUnmanaged(Decl, void) = .empty;
    for (functions.items) |decl| {
        try queue.append(self.gpa, decl);
        try queued.put(self.gpa, decl, {});
    }
    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        const decl = queue.items[next];
        _ = queued.remove(decl);
        var more: std.ArrayList(ParameterCopy) = .empty;
        // Each held copy its own, as a route found crowded is marked in place.
        for (found.get(decl) orelse &.{}) |copy| try more.append(self.gpa, copy);
        self.copies = found;
        if (!try self.passedCopies(decl, passes.get(decl).?, &more)) continue; // unreachable: every function's calls are read above
        try found.put(self.gpa, decl, more.items);
        for (if (callers.get(decl)) |list| list.items else &.{}) |caller| {
            if ((try queued.getOrPut(self.gpa, caller)).found_existing) continue;
            try queue.append(self.gpa, caller);
        }
    }
    self.copies = found;
    var it = found.iterator();
    while (it.next()) |entry| {
        const name = self.project.at(entry.key_ptr.file).model.declarations[@backingInt(entry.key_ptr.index)].name;
        const kind: Copies = for (entry.value_ptr.*) |copy| {
            if (copy.kind != .moved) break .copies;
        } else .moves;
        // Functions of one name: the one that copies decides.
        const slot = try self.copier_names.getOrPut(self.gpa, name);
        if (!slot.found_existing or kind == .copies) slot.value_ptr.* = kind;
    }
    if (self.check_records) |check| try check.copies(self, &self.copies.?);
}

/// What a function named `name` may do with a generic parameter's values.
pub const Copies = enum {
    /// No function so named copies one.
    none,
    /// Those so named only move a parameter's value into storage (`ParameterCopy.kind ==
    /// .moved`): what a call gives is copied there only where the argument does not move at
    /// the call.
    moves,
    /// Some function so named copies one.
    copies,
};

/// What some function named `name` does with a generic parameter's values: one answer, so a
/// reader cannot take a mover for a function that copies nothing.
pub fn copiesBy(self: *Facts, name: []const u8) ResolveError!Copies {
    if (self.copies == null) try self.findCopies();
    return self.copier_names.get(name) orelse .none;
}

fn syntaxOf(self: *const Facts, file: Project.FileId) *const Ast {
    return &self.project.at(file).file.tree;
}

/// Whether an import no mapping gives is Zig's own per-build file: `builtin`, which the
/// compiler gives every module (the target and build options it is built for), or `root` as
/// one of std's files reads it (the program std is in; a program's own `root` is a file the
/// build maps).
fn zigOwn(self: *Facts, file: Project.FileId, spelling: []const u8) ResolveError!bool {
    if (std.mem.eql(u8, spelling, "builtin")) return true;
    if (!std.mem.eql(u8, spelling, "root")) return false;
    return (try self.outside()).std_files.contains(@backingInt(file));
}

/// Whether `file` is one of std's: a file std's import reaches.
pub fn standard(self: *Facts, file: Project.FileId) ResolveError!bool {
    return (try self.outside()).std_files.contains(@backingInt(file));
}

/// Whether `file` is the program's: every loaded file but those std's import reaches and those
/// a known library's module roots reach (`known`), which the analyses know by their
/// declarations. A file of the package the run did not select and a dependency's are the
/// program's as much as a selected one: what they do runs as its own, so a scan of "every use
/// in the program" reads them, and one that stops at a selection decides nothing past it.
pub fn program(self: *Facts, file: Project.FileId) ResolveError!bool {
    return (try self.outside()).own(file);
}

/// The files that are not the program's, found once: std's and the known libraries'.
pub fn outside(self: *Facts) ResolveError!*const Outside {
    const found = try self.memo(Outside);
    if (found.built) return found;
    found.built = true;
    found.project = self.project;
    for (self.project.imports) |mapping| if (std.mem.eql(u8, mapping.spelling, "std")) try found.std_files.put(self.gpa, @backingInt(mapping.target), {});
    try self.reach(&found.std_files, .standard);
    for (self.project.sources) |*source| if (self.knownFile(source.id)) try found.known_files.put(self.gpa, @backingInt(source.id), {});
    return found;
}
pub const Outside = struct {
    /// The files std's import reaches.
    std_files: FileSet = .empty,
    /// The files a known library's module roots reach, std's aside.
    known_files: FileSet = .empty,
    project: *const Project = undefined,
    built: bool = false,

    /// Whether `file` is the program's. A file the run selected is: what is linted is the
    /// program, a library's own sources among them when the run is the library's.
    pub fn own(self: *const Outside, file: Project.FileId) bool {
        if (self.project.at(file).input.selected) return true;
        return !self.std_files.contains(@backingInt(file)) and !self.known_files.contains(@backingInt(file));
    }
};

/// Grows `files` to every file their imports reach. std's reach follows every import of its
/// own; a library's stops at std, builtin and root, which are not its files.
fn reach(self: *Facts, files: *FileSet, from: enum { standard, library }) ResolveError!void {
    var growing = true;
    while (growing) {
        growing = false;
        for (self.project.imports) |mapping| {
            if (!files.contains(@backingInt(mapping.from)) or files.contains(@backingInt(mapping.target))) continue;
            if (from == .library and (std.mem.eql(u8, mapping.spelling, "std") or std.mem.eql(u8, mapping.spelling, "builtin") or std.mem.eql(u8, mapping.spelling, "root"))) continue;
            try files.put(self.gpa, @backingInt(mapping.target), {});
            growing = true;
        }
    }
}
/// Files by their ids' numbers.
pub const FileSet = std.AutoHashMapUnmanaged(u32, void);

/// The position of each parameter of `function` that takes a type or `anytype`, by its
/// declaration's index; null for any other parameter.
fn genericPosition(self: *const Facts, function: Decl, parameter: Model.Declaration.Id) ?usize {
    const model = &self.project.at(function.file).model;
    const record = model.declarations[@backingInt(parameter)];
    if (record.kind != .parameter or model.scopes[@backingInt(record.scope)].node != self.scopeNode(function)) return null;
    const t = self.syntaxOf(function.file);
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = t.fullFnProto(&fn_buffer, model.declarations[@backingInt(function.index)].node) orelse return null;
    var it = proto.iterate(t);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (param.name_token != record.token) continue;
        if (param.anytype_ellipsis3 != null) return position;
        const type_expr = param.type_expr orelse return null;
        return if (typeKeyword(t, type_expr)) position else null;
    }
    return null;
}

/// The position of `function`'s parameter named at `token`, when it is `anytype`.
pub fn anytypeAt(self: *const Facts, function: Decl, token: Ast.TokenIndex) ?usize {
    const t = self.syntaxOf(function.file);
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = t.fullFnProto(&fn_buffer, self.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return null;
    var it = proto.iterate(t);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (param.name_token == token) return if (param.anytype_ellipsis3 != null) position else null;
    }
    return null;
}

pub fn hasGenericParameter(self: *const Facts, function: Decl) bool {
    const t = self.syntaxOf(function.file);
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = t.fullFnProto(&fn_buffer, self.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return false;
    var it = proto.iterate(t);
    while (it.next()) |param| {
        if (param.anytype_ellipsis3 != null) return true;
        if (param.type_expr) |type_expr| if (typeKeyword(t, type_expr)) return true;
    }
    return false;
}

/// The generic parameter whose value `value` is: a parameter of `function` declared `T` of a
/// type parameter, or an `anytype` parameter, its own argument's value. A `comptime` one's
/// value is known as the program compiles and holds nothing at run time: none.
fn valueOfParameter(self: *const Facts, function: Decl, value: Model.Declaration.Id) ?usize {
    const model = &self.project.at(function.file).model;
    const record = model.declarations[@backingInt(value)];
    if (record.kind != .parameter or model.scopes[@backingInt(record.scope)].node != self.scopeNode(function)) return null;
    const t = self.syntaxOf(function.file);
    if (record.token > 0 and t.tokenTag(record.token - 1) == .keyword_comptime) return null;
    if (self.anytypeAt(function, record.token)) |position| return position;
    if (t.nodeTag(record.node) != .identifier) return null;
    const named = (model.reference(record.node) orelse return null).declaration orelse return null;
    return self.genericPosition(function, named);
}

/// `const x = v;` in `function`'s own body, `v` a value of a generic parameter.
fn directCopies(self: *Facts, function: Decl, out: *std.ArrayList(ParameterCopy)) ResolveError!void {
    const t = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const whole = self.scopeNode(function);
    for (model.declarations) |d| {
        // A local of the body: a declaration of a container it returns is comptime.
        if (d.kind != .variable or model.scopes[@backingInt(d.scope)].kind != .block or !self.enclosed(function.file, d.scope, whole)) continue;
        const v = t.fullVarDecl(d.node) orelse continue;
        if (v.comptime_token != null) continue;
        // A `comptime` block runs as the program compiles: its locals copy nothing at run time.
        if (inComptime(t, model, d.node)) continue;
        const init = v.ast.init_node.unwrap() orelse continue;
        // What a call a parameter decides makes is no copy of it (`madeCalls`).
        if (self.madeByParameter(function.file, init) != null) continue;
        if (t.nodeTag(init) == .identifier) {
            const named = (model.reference(init) orelse continue).declaration orelse continue;
            const position = self.valueOfParameter(function, named) orelse continue;
            try out.append(self.gpa, .{ .position = position, .site = .{ .file = function.file, .node = d.node } });
            continue;
        }
        // A value chosen or wrapped (`out catch |e| return e`, `if (c) v.a else v.b`): each
        // place it reads that a generic parameter gives, read with the binding's arguments.
        // Into a type written apart from the parameters (`const kind: Kind = ...`) it is the
        // same copy in every binding, decided where it is written.
        if (v.ast.type_node.unwrap()) |declared| if (self.derivedParameter(function, declared, 0) == null) continue;
        const parts = try self.copiedParts(function.file, init);
        for (parts.places) |place| {
            const position = self.runtimeParameter(function, place, 0) orelse continue;
            // The parameter itself is its argument, read as written where it is bound
            // (`const both: [2]@TypeOf(x) = .{ x, x }`); a part whose value resolves where it
            // is written is the same copy in every binding, decided there.
            const itself = t.nodeTag(place) == .identifier and if (model.reference(place)) |ref| if (ref.declaration) |named| self.valueOfParameter(function, named) != null else false else false;
            if (!itself and try self.resolve(function.file, place) != .unknown) continue;
            // The parameter itself held once, in no loop, by a local nothing else holds it in
            // is moved there (`const held: [1]@TypeOf(x) = .{x};`), as a write is.
            if (itself and !self.inLoop(function, d.node) and self.holdingReads(function, model.reference(place).?.declaration.?) == 1) continue;
            const site: Key = .{ .file = function.file, .node = d.node };
            try out.append(self.gpa, .{ .position = position, .site = site, .source = if (itself) null else .{ .file = function.file, .node = place } });
            try self.bound_places.put(self.gpa, .{ .site = site, .place = place }, function);
        }
    }
    try self.storedCopies(function, out);
    try self.scalarCasts(function, out);
    try self.madeCalls(function, out);
}

/// Each call in `function`'s body, outside `comptime`, whose generic parameter decides what it
/// makes (`madeBy`): a `made` copy, its source the call itself, so each binding reads what that
/// call makes with its own arguments (`boundCopy`).
fn madeCalls(self: *Facts, function: Decl, out: *std.ArrayList(ParameterCopy)) ResolveError!void {
    const t = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const whole = self.scopeNode(function);
    const first = t.firstToken(whole);
    const last = t.lastToken(whole);
    for (0..t.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = t.nodeMainToken(node);
        if (at < first or at > last) continue;
        var call_buffer: [1]Ast.Node.Index = undefined;
        if (t.fullCall(&call_buffer, node) == null) continue;
        const made = self.madeBy(function.file, node) orelse continue;
        if (!std.meta.eql(made.function, function) or inComptime(t, model, node)) continue;
        const site: Key = .{ .file = function.file, .node = node };
        try out.append(self.gpa, .{ .position = made.position, .site = site, .kind = .made, .source = site });
    }
}

/// What `function`'s own `return`s, assignments, destructures and calls write of a generic
/// parameter's value, as `directCopies` reads a local's initializer: the parameter or a part of
/// it (`return .{ x, x }`, `out[0] = x;`, `a.*, b.* = .{ x, x };`, a literal whose address is
/// taken), or the parameter itself handed by value to a call (`list.appendAssumeCapacity(x)`,
/// by `calls`; a receiver is the value's own method). The parameter itself written once, in no
/// loop, where nothing else in the body may hold it (`holdingReads`), is moved there
/// (`out.* = x;`); else each such write is a copy.
fn storedCopies(self: *Facts, function: Decl, out: *std.ArrayList(ParameterCopy)) ResolveError!void {
    const t = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const whole = self.scopeNode(function);
    const body = t.nodeData(whole).node_and_node[1];
    const first = t.firstToken(body);
    const last = t.lastToken(body);
    for (t.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = t.nodeMainToken(node);
        if (at < first or at > last) continue;
        var one: [1]Ast.Node.Index = undefined;
        const values: []const Ast.Node.Index = switch (tag) {
            .@"return" => blk: {
                one[0] = t.nodeData(node).opt_node.unwrap() orelse continue;
                break :blk &one;
            },
            .assign => blk: {
                const sides = t.nodeData(node).node_and_node;
                if (t.nodeTag(sides[0]) == .identifier and std.mem.eql(u8, t.tokenSlice(t.nodeMainToken(sides[0])), "_")) continue;
                one[0] = sides[1];
                break :blk &one;
            },
            .assign_destructure => blk: {
                one[0] = t.assignDestructure(node).ast.value_expr;
                break :blk &one;
            },
            // A literal whose address is taken (`@memcpy(out, &[2]@TypeOf(x){ x, x })`): a
            // temporary holding what it copies.
            .address_of => blk: {
                const operand = t.nodeData(node).node;
                var buffer: [2]Ast.Node.Index = undefined;
                if (t.fullArrayInit(&buffer, operand) == null and t.fullStructInit(&buffer, operand) == null) continue;
                one[0] = operand;
                break :blk &one;
            },
            .call_one, .call_one_comma, .call, .call_comma => blk: {
                const call = (try calls.at(self, function.file, node)) orelse continue;
                const args = switch (call.args) {
                    .known => |each| each,
                    .unknown => continue,
                };
                break :blk if (call.receiver == .bound) args[1..] else args;
            },
            else => continue,
        };
        // The function's own statement, run as it runs: not a nested function's or a
        // `comptime` block's.
        if (self.innermostFunction(function.file, model.scopeOf(at)) != whole or inComptime(t, model, node)) continue;
        const looped = self.inLoop(function, node);
        for (values) |value| {
            const handed = tag != .@"return" and tag != .assign and tag != .assign_destructure and tag != .address_of;
            const parts = try self.copiedParts(function.file, value);
            for (parts.places) |place| {
                const position = self.runtimeParameter(function, place, 0) orelse continue;
                const named: ?Model.Declaration.Id = if (t.nodeTag(place) == .identifier) if (model.reference(place)) |ref| ref.declaration else null else null;
                // The parameter itself is its argument, read as written where it is bound; a part
                // whose value resolves where it is written is the same copy in every binding.
                const itself = if (named) |index| self.valueOfParameter(function, index) != null else false;
                if (!itself and try self.resolve(function.file, place) != .unknown) continue;
                // A call takes the parameter itself only, as a pass-on reads a part.
                if (handed and !itself) continue;
                // Moved: written once, read nowhere else, and copied once by this value
                // (`@splat(x)` copies it into each element).
                var copied: usize = 0;
                for (parts.places) |other| copied += @intFromBool(other == place);
                const moving = itself and !looped and self.holdingReads(function, named.?) == 1 and copied == 1;
                const site: Key = .{ .file = function.file, .node = node };
                try out.append(self.gpa, .{ .position = position, .site = site, .kind = if (moving) .moved else .copy, .source = if (itself) null else .{ .file = function.file, .node = place } });
                try self.bound_places.put(self.gpa, .{ .site = site, .place = place }, function);
            }
        }
    }
}

/// Whether `node` runs in a loop of `function`'s body, which may run it more than once.
fn inLoop(self: *const Facts, function: Decl, node: Ast.Node.Index) bool {
    const t = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const body = t.nodeData(self.scopeNode(function)).node_and_node[1];
    var up = model.parentOf(node);
    while (up) |parent| : (up = model.parentOf(parent)) {
        if (parent == body) return false;
        if (t.fullWhile(parent) != null or t.fullFor(parent) != null) return true;
    }
    return false;
}

/// The function node of the innermost function `scope` is in, if any.
fn innermostFunction(self: *const Facts, file: Project.FileId, scope: Model.Scope.Id) ?Ast.Node.Index {
    const scopes = self.project.at(file).model.scopes;
    var at: ?Model.Scope.Id = scope;
    while (at) |s| : (at = scopes[@backingInt(s)].parent) {
        if (scopes[@backingInt(s)].kind == .function) return scopes[@backingInt(s)].node;
    }
    return null;
}

/// How many reads in `function`'s body may hold the value of the declaration `index`, whole or
/// a part (`mayHold`).
fn holdingReads(self: *const Facts, function: Decl, index: Model.Declaration.Id) usize {
    const t = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const body = t.nodeData(self.scopeNode(function)).node_and_node[1];
    const first = t.firstToken(body);
    const last = t.lastToken(body);
    var count: usize = 0;
    for (t.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = t.nodeMainToken(node);
        if (at < first or at > last) continue;
        const ref = model.reference(node) orelse continue;
        if (ref.declaration != index) continue;
        if (mayHold(t, model, node)) count += 1;
    }
    return count;
}

/// Whether the read `node` may hold the value it names, whole or a part: not an operand of an
/// arithmetic, bit, comparison or boolean operator, nor of a builtin that makes a number or a
/// pointer of it (`@intCast(x)`), nor of a type query (`@TypeOf(x)`); none of those holds an
/// owner.
fn mayHold(t: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var up = model.parentOf(node);
    while (up) |parent| : (up = model.parentOf(parent)) switch (t.nodeTag(parent)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => if (unevaluated(t.tokenSlice(t.nodeMainToken(parent)))) return false,
        .fn_decl => break,
        else => {},
    };
    const parent = model.parentOf(node) orelse return true;
    return switch (t.nodeTag(parent)) {
        .add, .sub, .mul, .div, .mod, .shl, .shl_sat, .shr, .bit_and, .bit_or, .bit_xor, .add_wrap, .sub_wrap, .mul_wrap, .add_sat, .sub_sat, .mul_sat, .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .bool_and, .bool_or, .bool_not, .negation, .negation_wrap, .bit_not => false,
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => blk: {
            const name = t.tokenSlice(t.nodeMainToken(parent));
            for ([_][]const u8{ "@as", "@bitCast", "@field", "@unionInit" }) |through| if (std.mem.eql(u8, name, through)) break :blk true;
            break :blk false;
        },
        else => true,
    };
}

/// The integers made into a type, or read out of a value, by the type of `function`'s generic
/// parameter: `@enumFromInt` and `@fromBackingInt` into a type its result place writes in terms
/// of one (`@as(@TypeOf(library).Role, ...)`); `@bitCast` and `@ptrCast` into one, or of a value
/// one gives; `@intFromEnum`, `@backingInt` and a call of
/// `raw` (`x.raw()`, `T.raw(x)`, `@call(.auto, T.raw, .{x})`) of a value one gives. Each is
/// the binding's: its type is the bound one's (`kind = .cast`, `source` the type written, or
/// the value read).
fn scalarCasts(self: *Facts, function: Decl, out: *std.ArrayList(ParameterCopy)) ResolveError!void {
    const t = self.syntaxOf(function.file);
    const whole = self.scopeNode(function);
    const first = t.firstToken(whole);
    const last = t.lastToken(whole);
    for (t.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = t.nodeMainToken(node);
        if (at < first or at > last) continue;
        const source: Ast.Node.Index = switch (tag) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => blk: {
                const name = t.tokenSlice(at);
                var buffer: [2]Ast.Node.Index = undefined;
                const args = builtinArgs(t, node, &buffer);
                if (std.mem.eql(u8, name, "@enumFromInt") or std.mem.eql(u8, name, "@fromBackingInt")) break :blk self.writtenType(function.file, node, 0) orelse continue;
                if ((std.mem.eql(u8, name, "@intFromEnum") or std.mem.eql(u8, name, "@backingInt")) and args.len == 1) break :blk args[0];
                // Bits reinterpreted: a value one gives read as another type, or a type written
                // in terms of one made out of another's bits.
                if ((std.mem.eql(u8, name, "@bitCast") or std.mem.eql(u8, name, "@ptrCast")) and args.len == 1) {
                    if (self.runtimeParameter(function, args[0], 0) != null) break :blk args[0];
                    break :blk self.writtenType(function.file, node, 0) orelse continue;
                }
                // `@call(modifier, T.raw, .{x})`: the value it is given.
                if (std.mem.eql(u8, name, "@call") and args.len == 3) {
                    var tuple_buffer: [2]Ast.Node.Index = undefined;
                    const tuple = t.fullArrayInit(&tuple_buffer, args[2]) orelse continue;
                    if (tuple.ast.elements.len != 1 or !spelledAs(t, args[1], "raw")) continue;
                    break :blk tuple.ast.elements[0];
                }
                continue;
            },
            // A scalar's `raw` called on a value a generic parameter gives: `x.raw()`, or
            // `T.raw(x)` given it.
            .call_one, .call_one_comma, .call, .call_comma => blk: {
                var call_buffer: [1]Ast.Node.Index = undefined;
                const call = t.fullCall(&call_buffer, node).?; // unreachable: the tag is a call's
                if (!spelledAs(t, call.ast.fn_expr, "raw")) continue;
                if (call.ast.params.len == 0 and t.nodeTag(call.ast.fn_expr) == .field_access) break :blk t.nodeData(call.ast.fn_expr).node_and_token[0];
                if (call.ast.params.len == 1) break :blk call.ast.params[0];
                continue;
            },
            else => continue,
        };
        const position = self.derivedParameter(function, source, 0) orelse continue;
        const site: Key = .{ .file = function.file, .node = node };
        try out.append(self.gpa, .{ .position = position, .site = site, .kind = .cast, .source = .{ .file = function.file, .node = source } });
        try self.cast_sites.put(self.gpa, site, function);
    }
}

/// Whether `callee` is spelled with the name `name` (`x.raw`, `Index.raw`, `raw`).
fn spelledAs(t: *const Ast, callee: Ast.Node.Index, name: []const u8) bool {
    const token = switch (t.nodeTag(callee)) {
        .field_access => t.nodeData(callee).node_and_token[1],
        .identifier => t.nodeMainToken(callee),
        else => return false,
    };
    return std.mem.eql(u8, t.tokenSlice(token), name);
}

/// The type written for the place `node`'s value goes to: `@as`'s, a declaration's, the
/// function's result for a `return`, through a grouping, `try`, either side of `orelse` or
/// `catch`, a branch or a prong. Null where none is written there.
fn writtenType(self: *Facts, file: Project.FileId, node: Ast.Node.Index, depth: usize) ?Ast.Node.Index {
    if (depth == 16) return null;
    const t = self.syntaxOf(file);
    const model = &self.project.at(file).model;
    const parent = model.parentOf(node) orelse return null;
    if (t.fullVarDecl(parent)) |variable| return if (variable.ast.init_node.unwrap() == node) variable.ast.type_node.unwrap() else null;
    switch (t.nodeTag(parent)) {
        .grouped_expression, .@"try", .@"orelse", .@"catch", .@"if", .if_simple, .@"switch", .switch_comma, .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => return self.writtenType(file, parent, depth + 1),
        .@"return" => {
            var at: ?Ast.Node.Index = model.parentOf(parent);
            while (at) |candidate| : (at = model.parentOf(candidate)) {
                if (t.nodeTag(candidate) != .fn_decl) continue;
                var fn_buffer: [1]Ast.Node.Index = undefined;
                return (t.fullFnProto(&fn_buffer, t.nodeData(candidate).node_and_node[0]) orelse return null).ast.return_type.unwrap();
            }
            return null;
        },
        .builtin_call_two, .builtin_call_two_comma => {
            if (!std.mem.eql(u8, t.tokenSlice(t.nodeMainToken(parent)), "@as")) return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = builtinArgs(t, parent, &buffer);
            return if (args.len == 2 and args[1] == node) args[0] else null;
        },
        else => return null,
    }
}

/// Whether the builtin or `raw` call `node` makes or reads an integer by the type of a generic
/// parameter, which each binding of the generic decides (`scalarCasts`): where every binding is
/// a call a run judges (`judgedAtBindings`). One std may call on a context it is handed
/// (`HashMap`'s `hash(key)`) is bound past the calls a rule judges, so it is judged where it
/// is written too, its value as unknown as that leaves it.
pub fn castAtBinding(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    if (self.copies == null) try self.findCopies();
    const function = self.cast_sites.get(.{ .file = file, .node = node }) orelse return false;
    return self.judgedAtBindings(function);
}

/// Whether the `raw` call `node` on a generic parameter's value is each binding's
/// (`castAtBinding`), the program binding it: a receiver no call of the run binds is given
/// whatever a binding gives, unresolved where it is read.
pub fn rawAtBinding(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    if (self.copies == null) try self.findCopies();
    const function = self.cast_sites.get(.{ .file = file, .node = node }) orelse return false;
    return (try self.namedCalls(function) orelse return false) != 0;
}

/// What a copy of the value written `node` copies: the places it reads (a name, a field,
/// `@field`, what a pointer points at, an element, an optional's payload), followed through
/// every way a value is chosen or wrapped (a branch, a prong, a `break`, `orelse`, `catch`,
/// `try`, `@as`, `@bitCast`, `@unionInit`, `++`, a literal's parts); and the values of other
/// shapes, decided by their type. A call's result, a literal of plain data, a pointer and a
/// branch that leaves are no copy of a place; `results` are the calls (`@call` among them)
/// whose results it copies, each a temporary. `deep` is a value nested past what is followed.
pub const Copied = struct { places: []const Ast.Node.Index, rest: []const Ast.Node.Index, results: []const Ast.Node.Index, deep: ?Ast.Node.Index };

pub fn copiedParts(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Copied {
    var places: std.ArrayList(Ast.Node.Index) = .empty;
    var rest: std.ArrayList(Ast.Node.Index) = .empty;
    var results: std.ArrayList(Ast.Node.Index) = .empty;
    var deep: ?Ast.Node.Index = null;
    try self.copiedWalk(file, node, 0, &places, &rest, &results, &deep);
    return .{ .places = places.items, .rest = rest.items, .results = results.items, .deep = deep };
}

fn copiedWalk(self: *Facts, file: Project.FileId, node: Ast.Node.Index, depth: usize, places: *std.ArrayList(Ast.Node.Index), rest: *std.ArrayList(Ast.Node.Index), results: *std.ArrayList(Ast.Node.Index), deep: *?Ast.Node.Index) ResolveError!void {
    if (depth == 64) {
        if (deep.* == null) deep.* = node;
        return;
    }
    const t = self.syntaxOf(file);
    switch (t.nodeTag(node)) {
        .identifier, .field_access, .deref, .array_access, .unwrap_optional => return places.append(self.gpa, node),
        .grouped_expression => return self.copiedWalk(file, t.nodeData(node).node_and_token[0], depth + 1, places, rest, results, deep),
        .@"try", .@"comptime", .@"nosuspend" => return self.copiedWalk(file, t.nodeData(node).node, depth + 1, places, rest, results, deep),
        .@"orelse", .@"catch", .array_cat => {
            const sides = t.nodeData(node).node_and_node;
            try self.copiedWalk(file, sides[0], depth + 1, places, rest, results, deep);
            return self.copiedWalk(file, sides[1], depth + 1, places, rest, results, deep);
        },
        .@"if", .if_simple => {
            const branch = t.fullIf(node).?; // unreachable: the tag is an `if`'s
            // A condition known as the program compiles: Zig analyses only the branch it takes.
            if (branch.payload_token == null and branch.error_token == null) if (try self.comptimeTruth(null, file, branch.ast.cond_expr)) |taken| {
                const chosen = if (taken) branch.ast.then_expr else branch.ast.else_expr.unwrap() orelse return;
                return self.copiedWalk(file, chosen, depth + 1, places, rest, results, deep);
            };
            try self.copiedWalk(file, branch.ast.then_expr, depth + 1, places, rest, results, deep);
            if (branch.ast.else_expr.unwrap()) |otherwise| try self.copiedWalk(file, otherwise, depth + 1, places, rest, results, deep);
            return;
        },
        .@"switch", .switch_comma => {
            for (t.fullSwitch(node).?.ast.cases) |case| try self.copiedWalk(file, t.fullSwitchCase(case).?.ast.target_expr, depth + 1, places, rest, results, deep); // unreachable: the tag is a switch's, its cases are cases
            return;
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            // A block with no label gives `void`; one with a label, what each `break` out of it does.
            for (try self.breaksOut(file, node)) |value| try self.copiedWalk(file, value, depth + 1, places, rest, results, deep);
            return;
        },
        // A loop's value: each `break` out of it, and its `else`.
        .@"for", .for_simple, .@"while", .while_simple, .while_cont => {
            for (try self.breaksOut(file, node)) |value| try self.copiedWalk(file, value, depth + 1, places, rest, results, deep);
            const otherwise = if (t.fullFor(node)) |loop| loop.ast.else_expr else t.fullWhile(node).?.ast.else_expr; // unreachable: the tag is a loop's
            if (otherwise.unwrap()) |value| try self.copiedWalk(file, value, depth + 1, places, rest, results, deep);
            return;
        },
        // What a call returns is the callee's, its `return` checked there.
        .call_one, .call_one_comma, .call, .call_comma => return results.append(self.gpa, node),
        // No value: control leaves.
        .@"return", .@"break", .@"continue", .unreachable_literal => return,
        // A pointer, or a slice of what it points at: an alias.
        .address_of, .slice, .slice_open, .slice_sentinel => return,
        // A number, text, an error, or an enum's tag; or a declaration literal (`.empty`),
        // which names a container's `const`, known as the program compiles.
        .number_literal, .char_literal, .string_literal, .multiline_string_literal, .error_value, .enum_literal => return,
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = t.tokenSlice(t.nodeMainToken(node));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = builtinArgs(t, node, &buffer);
            if (std.mem.eql(u8, name, "@field")) return places.append(self.gpa, node);
            if (args.len != 0 and (std.mem.eql(u8, name, "@as") or std.mem.eql(u8, name, "@bitCast"))) return self.copiedWalk(file, args[args.len - 1], depth + 1, places, rest, results, deep);
            if (args.len == 3 and std.mem.eql(u8, name, "@unionInit")) return self.copiedWalk(file, args[2], depth + 1, places, rest, results, deep);
            if (std.mem.eql(u8, name, "@call")) return results.append(self.gpa, node);
            // `@splat(x)` fills an array (or a vector) of any element type with copies of `x`:
            // read twice, as an array of more than one element copies it.
            if (args.len == 1 and std.mem.eql(u8, name, "@splat")) {
                try self.copiedWalk(file, args[0], depth + 1, places, rest, results, deep);
                return self.copiedWalk(file, args[0], depth + 1, places, rest, results, deep);
            }
            // Every other builtin gives no owner's copy: a number, an enum, a pointer, a
            // type, text, an error or nothing (`@intCast`, `@fromBackingInt`, `@ptrCast`,
            // `@This`, `@tagName`, `@memcpy`).
            return;
        },
        else => {
            var buffer: [2]Ast.Node.Index = undefined;
            if (t.fullStructInit(&buffer, node)) |literal| {
                for (literal.ast.fields) |field| try self.copiedWalk(file, field, depth + 1, places, rest, results, deep);
                return;
            }
            if (t.fullArrayInit(&buffer, node)) |literal| {
                for (literal.ast.elements) |item| try self.copiedWalk(file, item, depth + 1, places, rest, results, deep);
                return;
            }
            return rest.append(self.gpa, node);
        },
    }
}

/// The values each `break` that leaves `node` gives: a labeled block, a loop or a labeled
/// `switch`, as `accesses.breakTarget` reads where a `break` goes (its label's, or with none the
/// loop whose body holds it: one in a loop's condition or `else` leaves an outer one). A `break`
/// with no value gives none.
pub fn breaksOut(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError![]const Ast.Node.Index {
    const t = self.syntaxOf(file);
    const model = &self.project.at(file).model;
    // A block or a `switch` with no label: no `break` leaves it (one with none leaves a loop).
    const labeled = switch (t.nodeTag(node)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon, .@"switch", .switch_comma => blk: {
            // The brace or `switch`, after its label where it has one.
            const start = t.nodeMainToken(node);
            break :blk start >= 2 and t.tokenTag(start - 1) == .colon and t.tokenTag(start - 2) == .identifier;
        },
        else => true,
    };
    if (!labeled) return &.{};
    var found: std.ArrayList(Ast.Node.Index) = .empty;
    const first = t.firstToken(node);
    const last = t.lastToken(node);
    for (t.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break") continue;
        const jump: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = t.nodeMainToken(jump);
        if (at < first or at > last or accesses.breakTarget(t, model, jump) != node) continue;
        try found.append(self.gpa, t.nodeData(jump).opt_token_and_opt_node[1].unwrap() orelse continue);
    }
    return found.items;
}

/// Whether the declaration `site` is a copy a generic function makes of its parameters'
/// values that its bindings decide (`parameterCopies`), reading `place`: where every binding is
/// a call a run judges (`judgedAtBindings`).
pub fn boundAtBinding(self: *Facts, file: Project.FileId, site: Ast.Node.Index, place: Ast.Node.Index) ResolveError!bool {
    if (self.copies == null) try self.findCopies();
    const function = self.bound_places.get(.{ .site = .{ .file = file, .node = site }, .place = place }) orelse return false;
    return self.judgedAtBindings(function);
}

/// The position of the generic parameter that decides what the call `value` makes (through
/// `try` or `catch`), a parameter of the function the call is in: a function of a type parameter
/// (`T.init(...)`, `comptime T: type`), or a method of a value of one (`probe.of(...)`,
/// `probe: Probe`) or of an `anytype` parameter, whose type its argument gives. Each binding
/// makes its own (`parameterCopies`' `made`).
pub fn madeByParameter(self: *const Facts, file: Project.FileId, value: Ast.Node.Index) ?usize {
    return (self.madeBy(file, value) orelse return null).position;
}

/// `madeByParameter`'s parameter and the function it is of.
fn madeBy(self: *const Facts, file: Project.FileId, value: Ast.Node.Index) ?struct { function: Decl, position: usize } {
    const t = self.syntaxOf(file);
    const made = switch (t.nodeTag(value)) {
        .@"try" => t.nodeData(value).node,
        .@"catch" => t.nodeData(value).node_and_node[0],
        else => value,
    };
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = t.fullCall(&call_buffer, made) orelse return null;
    if (t.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver = t.nodeData(call.ast.fn_expr).node_and_token[0];
    if (t.nodeTag(receiver) != .identifier) return null;
    const model = &self.project.at(file).model;
    const index = (model.reference(receiver) orelse return null).declaration orelse return null;
    const function = self.functionOf(.{ .file = file, .index = index }) orelse return null;
    // A type parameter's own function (`T.init()`), or a method of a value a binding types:
    // an `anytype` parameter's or one typed by a type parameter (`valueOfParameter`). A
    // `comptime` value holds nothing at run time, so nothing a call on it makes is a binding's.
    const anytype_value = self.anytypeAt(function, model.declarations[@backingInt(index)].token) != null;
    const position = (if (anytype_value) null else self.genericPosition(function, index)) orelse self.valueOfParameter(function, index) orelse return null;
    return .{ .function = function, .position = position };
}

/// A call in a generic's body passing one of its generic parameters on, or a part of one, and
/// the function it calls.
const Passing = struct { node: Ast.Node.Index, target: Decl };

/// The calls in `function`'s body that pass a generic parameter on, or a part of one.
fn passings(self: *Facts, function: Decl) ResolveError![]const Passing {
    const t = self.syntaxOf(function.file);
    const whole = self.scopeNode(function);
    const first = t.firstToken(whole);
    const last = t.lastToken(whole);
    var found: std.ArrayList(Passing) = .empty;
    for (t.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = t.fullCall(&call_buffer, node) orelse continue;
        const at = t.nodeMainToken(node);
        if (at < first or at > last) continue;
        var passes = false;
        for (call.ast.params) |arg| if (self.derivedParameter(function, arg, 0) != null) {
            passes = true;
        };
        if (!passes) continue;
        const callee = ((try self.definition(function.file, call.ast.fn_expr)).orNull()) orelse continue;
        const target = ((try self.origin(callee)).orNull()) orelse continue;
        if (std.meta.eql(target, function)) continue;
        try found.append(self.gpa, .{ .node = node, .target = target });
    }
    return found.items;
}

/// Each call of `passing` passing a generic parameter on where the callee copies the parameter
/// it takes: `function` copies its own, added to `out`. Whether `out` grew, or a route in it
/// was found crowded.
fn passedCopies(self: *Facts, function: Decl, passing: []const Passing, out: *std.ArrayList(ParameterCopy)) ResolveError!bool {
    const t = self.syntaxOf(function.file);
    var changed = false;
    for (passing) |each| {
        const node = each.node;
        const target = each.target;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = t.fullCall(&call_buffer, node).?; // unreachable: a passing is a call
        const theirs = self.copies.?.get(target) orelse continue;
        const receiver: usize = if (self.methodCall(function.file, call, target)) 1 else 0;
        for (theirs) |copy| {
            if (copy.position < receiver or copy.position - receiver >= call.ast.params.len) continue;
            const argument = call.ast.params[copy.position - receiver];
            const mine = self.derivedParameter(function, argument, 0) orelse continue;
            // A path through this call again is a cycle of generics passing it round.
            if (copy.source != null and onPath(copy.path, .{ .file = function.file, .node = node })) continue;
            // A route past those read stays past them for each caller.
            const passed: ParameterCopy = if (copy.source) |source| .{
                .position = mine,
                .site = copy.site,
                .kind = copy.kind,
                .source = source,
                .path = try std.mem.concat(self.gpa, Key, &.{ &.{.{ .file = function.file, .node = node }}, copy.path }),
                .crowded = copy.crowded,
            } else if (self.readThrough(function, argument, 0))
                .{ .position = mine, .site = copy.site, .kind = copy.kind, .source = .{ .file = function.file, .node = argument }, .crowded = copy.crowded }
            else
                .{ .position = mine, .site = copy.site, .kind = copy.kind, .crowded = copy.crowded };
            var seen: usize = 0;
            for (out.items) |*held| {
                if (held.position != passed.position or !std.meta.eql(held.site, passed.site) or !std.meta.eql(held.source, passed.source)) continue;
                if (samePath(held.path, passed.path)) {
                    if (passed.crowded and !held.crowded) {
                        held.crowded = true;
                        changed = true;
                    }
                    break;
                }
                seen += 1;
                if (seen == routes) {
                    if (!held.crowded) changed = true;
                    held.crowded = true;
                    break;
                }
            } else {
                try out.append(self.gpa, passed);
                changed = true;
            }
        }
    }
    return changed;
}

fn onPath(path: []const Key, step: Key) bool {
    for (path) |each| if (std.meta.eql(each, step)) return true;
    return false;
}

fn samePath(a: []const Key, b: []const Key) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

/// Whether `node` reads from a generic parameter of `function` what the parameter does not
/// hold: what calling it, or a method of it, returns, or what it points to. What it holds (a
/// field, an element, the payload of an optional or an error union) is the binding's argument's,
/// read whole where it is bound.
fn readThrough(self: *const Facts, function: Decl, node: Ast.Node.Index, depth: usize) bool {
    if (depth == 8) return false;
    const t = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const last = t.lastToken(node);
    for (t.firstToken(node)..last + 1) |raw| {
        const token: Ast.TokenIndex = @intCast(raw);
        if (t.tokenTag(token) != .identifier) continue;
        const index = self.lexical(function.file, model.scopeOf(token), t.tokenSlice(token)) orelse continue;
        const record = model.declarations[@backingInt(index)];
        if (self.genericPosition(function, index) != null or self.valueOfParameter(function, index) != null) {
            // `p(...)`, `p.f(...)`, `p.*`, `p.f.*`.
            var next = token + 1;
            while (next + 1 <= last and t.tokenTag(next) == .period and t.tokenTag(next + 1) == .identifier) next += 2;
            if (next <= last and (t.tokenTag(next) == .l_paren or t.tokenTag(next) == .period_asterisk)) return true;
            continue;
        }
        if (record.kind != .variable or !self.enclosed(function.file, record.scope, self.scopeNode(function))) continue;
        const init = (t.fullVarDecl(record.node) orelse continue).ast.init_node.unwrap() orelse continue;
        if (init != node and self.readThrough(function, init, depth + 1)) return true;
    }
    return false;
}

/// What a copy `function` makes holds at the binding `call` (`calls`): the binding's argument
/// read through the copy's `path` to its `source`, each call's arguments read with the bindings
/// of the one before (`bindTo`: a receiver the call passes first, each argument as its parameter
/// is typed). Arguments not known leave it unknown. Null where the binding makes no such copy:
/// a call on its path, or its source, is one no instantiation it makes compiles
/// (`reachedUnder`: a `switch` on its type information that takes another prong).
pub fn boundCopy(self: *Facts, call: calls.Call, function: Decl, copy: ParameterCopy) ResolveError!?Value {
    const bound = switch (try self.bindCall(&call, function, null)) {
        .reading => |reading| reading,
        .unknown => |why| return .{ .unknown = why },
    };
    // A choice of types bound to a type parameter (an `inline for`'s pass) is one instantiation
    // per type: each is read, and what they hold chosen as one.
    const readings = try self.instantiations(bound);
    var values: std.ArrayList(Value) = .empty;
    for (readings) |reading| {
        var walk: CrowdedWalk = .{};
        const found = if (copy.crowded) try self.crowdedIn(reading, function, copy.position, copy, &walk) else try self.copyIn(reading, copy);
        if (found) |value| try values.append(self.gpa, value);
    }
    if (values.items.len == 0) return null;
    return try self.choose(values.items);
}

/// How many instantiations a binding's choices of types are read as, at most: past it the
/// binding is read once, its choices as they are.
const instantiation_limit = 16;

/// The instantiations a reading stands for: one per type of each choice of types it binds a
/// parameter to (`choiceOfTypes`), as Zig compiles one per type; the reading itself where it
/// binds none, or more than `instantiation_limit` would be made.
fn instantiations(self: *Facts, env: *const Env) ResolveError![]const *const Env {
    var count: usize = 1;
    for (env.args) |arg| if (choiceOfTypes(arg)) {
        count *|= arg.alternatives.len;
    };
    if (count == 1 or count > instantiation_limit) return try self.gpa.dupe(*const Env, &.{env});
    const found = try self.gpa.alloc(*const Env, count);
    for (found, 0..) |*one, n| {
        const args = try self.gpa.dupe(Value, env.args);
        var rest = n;
        for (args) |*arg| if (choiceOfTypes(arg.*)) {
            const each = arg.alternatives;
            arg.* = each[rest % each.len];
            rest /= each.len;
        };
        var draft = env.*;
        draft.args = args;
        one.* = try self.keptReading(draft);
    }
    return found;
}

/// Whether `value` is a choice among types, each a type itself (a container, a type built from
/// its fields' types, a primitive), never a value of one.
fn choiceOfTypes(value: Value) bool {
    if (value != .alternatives) return false;
    for (value.alternatives) |one| switch (one) {
        .container, .primitive => {},
        .reified => |built| if (built.value) return false,
        else => return false,
    };
    return true;
}

/// The readings of the function a copy is in, as `call` binds `function` and the copy's path
/// passes the parameter on (`boundCopy`'s walk): one per instantiation that reaches the copy's
/// site, none where none does. Unknown where the binding or a call on the path does not resolve,
/// and for a crowded copy, which `boundCopy` reads by its routes, not one path. The list is the
/// caller's, in `gpa`; the readings themselves are kept as every reading is.
pub fn copyReadings(self: *Facts, gpa: std.mem.Allocator, call: calls.Call, function: Decl, copy: ParameterCopy) ResolveError!union(enum) { readings: []const *const Env, unknown: Unknown } {
    if (copy.crowded) return .{ .unknown = .budget };
    const bound = switch (try self.bindCall(&call, function, null)) {
        .reading => |reading| reading,
        .unknown => |why| return .{ .unknown = why },
    };
    var found: std.ArrayList(*const Env) = .empty;
    for (try self.instantiations(bound)) |reading| switch (try self.pathIn(reading, copy)) {
        .reading => |env| if (try self.reachedUnder(env, copy.site.file, copy.site.node)) try found.append(gpa, env),
        .unreached => {},
        .unknown => |why| return .{ .unknown = why },
    };
    return .{ .readings = found.items };
}

/// The reading of the function a copy is in, from `start`, the reading of the function the
/// binding binds, through each call on the copy's path.
fn pathIn(self: *Facts, start: *const Env, copy: ParameterCopy) ResolveError!union(enum) { reading: *const Env, unreached, unknown: Unknown } {
    var env = start;
    for (copy.path) |step| {
        if (!try self.reachedUnder(env, step.file, step.node)) return .unreached;
        const step_tree = self.syntaxOf(step.file);
        var step_buffer: [1]Ast.Node.Index = undefined;
        const inner = step_tree.fullCall(&step_buffer, step.node) orelse return .{ .unknown = .unsupported };
        const callee = switch (try self.definition(step.file, inner.ast.fn_expr)) {
            .decl => |d| d,
            .none => return .{ .unknown = .unresolved },
            .unknown => |why| return .{ .unknown = why },
        };
        const target = switch (try self.origin(callee)) {
            .decl => |d| d,
            .none => return .{ .unknown = .unresolved },
            .unknown => |why| return .{ .unknown = why },
        };
        env = try self.bind(step.file, inner, target, env);
    }
    return .{ .reading = env };
}

/// `boundCopy` in one instantiation `env` of the copy's function; null where the instantiation
/// does not reach a call on the path or the source.
fn copyIn(self: *Facts, start: *const Env, copy: ParameterCopy) ResolveError!?Value {
    return switch (try self.pathIn(start, copy)) {
        .reading => |env| self.sourceIn(env, copy),
        .unreached => null,
        .unknown => |why| .{ .unknown = why },
    };
}

/// What a copy's source holds in the reading `env` of the function it is in: null where the
/// reading does not reach it.
fn sourceIn(self: *Facts, env: *const Env, copy: ParameterCopy) ResolveError!?Value {
    const source = copy.source.?;
    if (!try self.reachedUnder(env, source.file, source.node)) return null;
    const value = try self.resolveIn(env, source.file, source.node);
    if (value != .unknown) return value;
    // What a copy writes is a value of its place's type, as Zig coerces it there: `return value`
    // in a function returning `E!T` writes a `T`, `slot.* = v` a `slot`'s pointee, each read in
    // this reading. A place that gives no type (an untyped `const`, an `anytype` argument) keeps
    // the value unknown.
    const placed = try self.castTypeIn(env, source.file, source.node);
    if (!placeTyped(placed)) return value;
    return try self.instance(placed);
}

/// Whether `place`, a place's type (`literalTypeIn`), names one: neither unknown nor `.scalar`
/// (no result type), nor a choice holding either.
fn placeTyped(place: Value) bool {
    return switch (place) {
        .unknown, .scalar => false,
        .alternatives => |each| for (each) |one| {
            if (!placeTyped(one)) break false;
        } else true,
        else => true,
    };
}

/// How many steps (a function's parameter in one reading, `CrowdedStep`) one crowded copy's
/// walk reads; past it, unknown. The walk is bounded by what it reads, not by how deep the calls
/// it follows nest: a step already answered is not read again.
const crowd_steps = 64;

/// `copyIn` for a copy crowded past `routes`, whose routes were not all kept: found in the
/// reading `env` of `function`, whose parameter `position` the copy is of. The source where
/// `function` writes it itself, and each call `function` makes that passes that parameter on
/// to a callee copying it to the same source, read where the reading reaches the call (as
/// `copyIn`'s path). A call already being read in the same reading adds nothing new: a cycle
/// of generics passing it round. Null where no route is reached; unknown past `crowd_steps`.
fn crowdedIn(self: *Facts, env: *const Env, function: Decl, position: usize, copy: ParameterCopy, walk: *CrowdedWalk) ResolveError!?Value {
    const here: CrowdedStep = .{ .env = env, .function = function, .position = position };
    const memory = try self.memo(Crowded);
    const key: CrowdedKey = .{ .step = here, .kind = copy.kind, .site = copy.site, .source = copy.source.?, .assumed = self.assumed };
    if (memory.found.get(key)) |kept| return kept;
    // A step the walk holds, being read or read in a cycle not yet closed, adds nothing new
    // here: what it reaches, the cycle's first step reads.
    for (walk.stack.items) |held| if (std.meta.eql(held.step, here)) {
        walk.low = @min(walk.low, held.at);
        return null;
    };
    if (walk.steps == crowd_steps) {
        walk.spent = true;
        return .{ .unknown = .budget };
    }
    walk.steps += 1;
    const mine = walk.count;
    walk.count += 1;
    const base = walk.stack.items.len;
    try walk.stack.append(self.gpa, .{ .step = here, .at = mine });
    const outer_low = walk.low;
    const outer_spent = walk.spent;
    walk.spent = false;
    const was_short = self.short;
    const met = self.open_met;
    const wide = self.wide;
    walk.low = std.math.maxInt(usize);
    const found = try self.crowdedRead(env, function, position, copy, walk);
    // Closed where every route cut was cut at this step or one read after it: the cycles it
    // is in close here (Tarjan's components, in the order the walk reads its steps). What a
    // step holds is what it reaches, chosen, and each step of a cycle reaches all the cycle
    // does: each held since this one began holds its answer, whichever binding asked first.
    // A step cut at one read before this one waits for that one to close. A component read
    // where the run's budget ran out, in it or in a unit it asked (`short`), holds what the
    // budget left it; one that met a query in progress (`open_met`: a resolution past its
    // depth, a cycle), what the asker's stack left it; one read wider than the analysis gives
    // (`wideSince`), more than it holds; one where the walk ran out of `crowd_steps`, unknown
    // for this walk only: each is this asker's answer, and none of it is kept.
    const closed = walk.low >= mine;
    if (closed) {
        const whole = !walk.spent and self.remaining != 0 and self.short == was_short and self.open_met == met and !self.wideSince(wide);
        if (whole) for (walk.stack.items[base..]) |held| try memory.found.put(self.gpa, .{ .step = held.step, .kind = copy.kind, .site = copy.site, .source = copy.source.?, .assumed = self.assumed }, found);
        walk.stack.items.len = base;
        walk.low = outer_low;
    } else walk.low = @min(outer_low, walk.low);
    walk.spent = outer_spent or walk.spent;
    return found;
}

/// `crowdedIn`, read.
fn crowdedRead(self: *Facts, env: *const Env, function: Decl, position: usize, copy: ParameterCopy, walk: *CrowdedWalk) ResolveError!?Value {
    var values: std.ArrayList(Value) = .empty;
    for (try self.parameterCopies(function)) |own| {
        if (own.path.len != 0 or own.position != position or !sameCopy(own, copy)) continue;
        if (try self.sourceIn(env, own)) |value| try values.append(self.gpa, value);
        break;
    }
    const t = self.syntaxOf(function.file);
    for (try self.passings(function)) |passing| {
        if (!try self.reachedUnder(env, function.file, passing.node)) continue;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = t.fullCall(&call_buffer, passing.node).?; // unreachable: a passing is a call
        const receiver: usize = if (self.methodCall(function.file, call, passing.target)) 1 else 0;
        var bound: ?*const Env = null;
        var seen: std.ArrayList(usize) = .empty;
        for (try self.parameterCopies(passing.target)) |theirs| {
            if (!sameCopy(theirs, copy)) continue;
            if (theirs.position < receiver or theirs.position - receiver >= call.ast.params.len) continue;
            if (std.mem.findScalar(usize, seen.items, theirs.position) != null) continue;
            if (self.derivedParameter(function, call.ast.params[theirs.position - receiver], 0) != position) continue;
            try seen.append(self.gpa, theirs.position);
            const reading = bound orelse try self.bind(function.file, call, passing.target, env);
            bound = reading;
            if (try self.crowdedIn(reading, passing.target, theirs.position, copy, walk)) |value| try values.append(self.gpa, value);
        }
    }
    if (values.items.len == 0) return null;
    return try self.choose(values.items);
}

/// A function's parameter being read for a crowded copy, in one reading.
const CrowdedStep = struct { env: *const Env, function: Decl, position: usize };

/// A step's answer is read under the asker's settled assumptions (`assumed`), as `resolve`
/// reads each node: one kept under one set is not another's.
const CrowdedKey = struct { step: CrowdedStep, kind: @FieldType(ParameterCopy, "kind"), site: Key, source: Key, assumed: ?Assumptions.Id };

/// `crowdedIn`'s answers by reading, function, parameter and copy, where they are whole.
const Crowded = struct {
    found: std.AutoHashMapUnmanaged(CrowdedKey, ?Value) = .empty,
};

/// One crowded copy's walk from a binding: the steps it holds, being read or read in a cycle
/// not yet closed, in the order they were begun, each with that order (at most `crowd_steps`,
/// so found by looking); how many it has begun; the earliest a route was cut at since the step
/// being read began; how many steps it has read; and whether one ran out of `crowd_steps`
/// since the step being read began.
const CrowdedWalk = struct {
    stack: std.ArrayList(struct { step: CrowdedStep, at: usize }) = .empty,
    count: usize = 0,
    low: usize = std.math.maxInt(usize),
    steps: usize = 0,
    spent: bool = false,
};

/// Whether two copies are of one write: the same site, kind and source.
fn sameCopy(a: ParameterCopy, b: ParameterCopy) bool {
    return a.kind == b.kind and std.meta.eql(a.site, b.site) and std.meta.eql(a.source, b.source);
}

/// Whether `node`, an identifier, names a `comptime` parameter.
pub fn comptimeParameter(self: *Facts, file: Project.FileId, node: Ast.Node.Index) bool {
    const t = self.syntaxOf(file);
    if (t.nodeTag(node) != .identifier) return false;
    const model = &self.project.at(file).model;
    const index = (model.reference(node) orelse return false).declaration orelse return false;
    const record = model.declarations[@backingInt(index)];
    return record.kind == .parameter and record.token > 0 and t.tokenTag(record.token - 1) == .keyword_comptime;
}

/// Whether `node`, an identifier, names a value of a type parameter of its function (`value`
/// of `value: T`): a copy of it is each binding's.
pub fn parameterValue(self: *Facts, file: Project.FileId, node: Ast.Node.Index) bool {
    const model = &self.project.at(file).model;
    if (self.syntaxOf(file).nodeTag(node) != .identifier) return false;
    const index = (model.reference(node) orelse return false).declaration orelse return false;
    const function = self.functionOf(.{ .file = file, .index = index }) orelse return false;
    return self.valueOfParameter(function, index) != null;
}

/// Whether `node` names a value of a generic parameter of a function whose bindings are all
/// calls a run judges, each deciding a copy of it (`parameterValue`, `judgedAtBindings`).
pub fn parameterAtBinding(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    if (!self.parameterValue(file, node)) return false;
    const model = &self.project.at(file).model;
    const index = model.reference(node).?.declaration.?; // unreachable: `parameterValue` holds only for a parameter's name
    return self.judgedAtBindings(self.functionOf(.{ .file = file, .index = index }).?); // unreachable: as above
}

/// Whether `node`, written in a generic function, is or is a part of one of its generic
/// parameters: a binding passed on, which the binding of that parameter decides.
pub fn fromParameter(self: *Facts, file: Project.FileId, node: Ast.Node.Index) bool {
    const t = self.syntaxOf(file);
    const model = &self.project.at(file).model;
    var up = model.parentOf(node);
    while (up) |parent| : (up = model.parentOf(parent)) {
        if (t.nodeTag(parent) != .fn_decl) continue;
        for (model.declarations, 0..) |d, i| {
            if (d.kind != .function) continue;
            const candidate: Decl = .{ .file = file, .index = @fromBackingInt(@intCast(i)) };
            if (self.scopeNode(candidate) != parent) continue;
            if (self.derivedParameter(candidate, node, 0) != null) return true;
            break;
        }
    }
    return false;
}

/// Whether `call` reaches `target` as a method of a value, which takes the value first.
fn methodCall(self: *const Facts, file: Project.FileId, call: Ast.full.Call, target: Decl) bool {
    const t = self.syntaxOf(file);
    if (t.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const target_tree = self.syntaxOf(target.file);
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = target_tree.fullFnProto(&fn_buffer, self.project.at(target.file).model.declarations[@backingInt(target.index)].node) orelse return false;
    var count: usize = 0;
    var it = proto.iterate(target_tree);
    while (it.next()) |_| count += 1;
    return count == call.ast.params.len + 1;
}

/// The generic parameter of `function` that `node` is or is a part of: the parameter itself, a
/// value of it, or what a capture or a constant reads of its type information.
fn derivedParameter(self: *const Facts, function: Decl, node: Ast.Node.Index, depth: usize) ?usize {
    if (depth == 8) return null;
    const t = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const first = t.firstToken(node);
    const last = t.lastToken(node);
    for (first..last + 1) |raw| {
        const token: Ast.TokenIndex = @intCast(raw);
        if (t.tokenTag(token) != .identifier) continue;
        const scope = model.scopeOf(token);
        const index = self.lexical(function.file, scope, t.tokenSlice(token)) orelse continue;
        const record = model.declarations[@backingInt(index)];
        if (self.genericPosition(function, index)) |position| return position;
        if (self.valueOfParameter(function, index)) |position| return position;
        if (!self.enclosed(function.file, record.scope, self.scopeNode(function))) continue;
        const source: Ast.Node.Index = switch (record.kind) {
            .variable => (t.fullVarDecl(record.node) orelse continue).ast.init_node.unwrap() orelse continue,
            .capture => self.captureSource(function.file, record) orelse continue,
            else => continue,
        };
        if (source == node) continue;
        if (self.derivedParameter(function, source, depth + 1)) |position| return position;
    }
    return null;
}

/// The generic parameter of `function` whose value at run time `node` reads, itself or
/// through a local: a value of one (`value: T`, `anytype`), or what calling one returns
/// (`handler()`, `T.init()`). A type parameter's declarations, a `comptime` parameter's parts
/// and what `@typeInfo` tells of them are known as the program compiles: none.
fn runtimeParameter(self: *const Facts, function: Decl, node: Ast.Node.Index, depth: usize) ?usize {
    if (depth == 8) return null;
    const t = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const last = t.lastToken(node);
    var skip_to: Ast.TokenIndex = 0;
    for (t.firstToken(node)..last + 1) |raw| {
        const token: Ast.TokenIndex = @intCast(raw);
        if (token < skip_to) continue;
        // What a type query is given is never evaluated: `@TypeOf(x)`, `@sizeOf(T)`.
        if (t.tokenTag(token) == .builtin and unevaluated(t.tokenSlice(token)) and token < last and t.tokenTag(token + 1) == .l_paren) {
            skip_to = closing(t, token + 1, last) + 1;
            continue;
        }
        if (t.tokenTag(token) != .identifier) continue;
        const index = self.lexical(function.file, model.scopeOf(token), t.tokenSlice(token)) orelse continue;
        const record = model.declarations[@backingInt(index)];
        if (self.valueOfParameter(function, index)) |position| return position;
        if (self.genericPosition(function, index)) |position| {
            // `p(...)`, `p.f(...)`.
            var next = token + 1;
            while (next + 1 <= last and t.tokenTag(next) == .period and t.tokenTag(next + 1) == .identifier) next += 2;
            if (next <= last and t.tokenTag(next) == .l_paren) return position;
            continue;
        }
        if (record.kind != .variable or !self.enclosed(function.file, record.scope, self.scopeNode(function))) continue;
        const v = t.fullVarDecl(record.node) orelse continue;
        if (v.comptime_token != null) continue;
        const init = v.ast.init_node.unwrap() orelse continue;
        if (init == node) continue;
        if (self.runtimeParameter(function, init, depth + 1)) |position| return position;
    }
    return null;
}

/// Whether `node` is inside a `comptime` block or expression.
fn inComptime(t: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var up = model.parentOf(node);
    while (up) |parent| : (up = model.parentOf(parent)) switch (t.nodeTag(parent)) {
        .@"comptime" => return true,
        .fn_decl => return false,
        else => {},
    };
    return false;
}

/// Whether a builtin only asks what its operands' types are, never evaluating them.
fn unevaluated(name: []const u8) bool {
    const queries = [_][]const u8{ "@TypeOf", "@typeInfo", "@sizeOf", "@alignOf", "@bitSizeOf", "@typeName", "@hasDecl", "@hasField", "@FieldType" };
    for (queries) |each| if (std.mem.eql(u8, name, each)) return true;
    return false;
}

/// The token closing the parenthesis that opens at `open`, at most `last`.
fn closing(t: *const Ast, open: Ast.TokenIndex, last: Ast.TokenIndex) Ast.TokenIndex {
    var depth: usize = 0;
    var token = open;
    while (token <= last) : (token += 1) switch (t.tokenTag(token)) {
        .l_paren => depth += 1,
        .r_paren => {
            depth -= 1;
            if (depth == 0) return token;
        },
        else => {},
    };
    return last;
}

/// The declaration `name` reaches from `scope`, looking outward.
fn lexical(self: *const Facts, file: Project.FileId, scope: Model.Scope.Id, name: []const u8) ?Model.Declaration.Id {
    const scopes = self.project.at(file).model.scopes;
    var at: ?Model.Scope.Id = scope;
    while (at) |s| : (at = scopes[@backingInt(s)].parent) if (scopes[@backingInt(s)].names.get(name)) |index| return index;
    return null;
}

/// What the capture `capture` is read from: a switch's subject, the loop's input at the
/// capture's position (`for (a, b) |x, y|`: `y` is `b`'s), an `if`'s or a `while`'s condition.
pub fn captureSource(self: *const Facts, file: Project.FileId, capture: Model.Declaration) ?Ast.Node.Index {
    const t = self.syntaxOf(file);
    const node = capture.node;
    if (t.fullSwitchCase(node) != null) {
        const parent = self.project.at(file).model.parentOf(node) orelse return null;
        return (t.fullSwitch(parent) orelse return null).ast.condition;
    }
    if (t.fullFor(node)) |loop| {
        const position = Model.capturePosition(t, loop, capture.token) orelse return null;
        return if (position < loop.ast.inputs.len) loop.ast.inputs[position] else null;
    }
    if (t.fullIf(node)) |branch| return branch.ast.cond_expr;
    if (t.fullWhile(node)) |loop| return loop.ast.cond_expr;
    return null;
}

/// The comptime `bool` parameter `node` names, if it names one.
fn conditionParameter(self: *const Facts, file: Project.FileId, node: Ast.Node.Index) ?Decl {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    const index = (model.reference(node) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(index)];
    if (record.kind != .parameter or !comptimeBool(tree, record)) return null;
    return .{ .file = file, .index = index };
}

/// The comptime enum parameter a `switch` operand names: one declared `comptime x: T` with `T`
/// a named type other than `type` and `bool`, whose prongs name its tags.
fn switchParameter(self: *const Facts, file: Project.FileId, node: Ast.Node.Index) ?Decl {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(node) != .identifier) return null;
    const model = &self.project.at(file).model;
    const index = (model.reference(node) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(index)];
    if (record.kind != .parameter or !comptimeNamed(tree, record)) return null;
    return .{ .file = file, .index = index };
}

fn comptimeNamed(tree: *const Ast, record: Model.Declaration) bool {
    if (record.token == 0 or tree.tokenTag(record.token - 1) != .keyword_comptime) return false;
    return switch (tree.nodeTag(record.node)) {
        .identifier => !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(record.node)), "type") and !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(record.node)), "bool"),
        .field_access => true,
        else => false,
    };
}

fn comptimeBool(tree: *const Ast, record: Model.Declaration) bool {
    return record.token > 0 and tree.tokenTag(record.token - 1) == .keyword_comptime and tree.nodeTag(record.node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(record.node)), "bool");
}

/// Whether `file` declares a comptime `bool` or enum parameter, whose conditions paths can settle.
fn hasConditions(self: *Facts, file: Project.FileId) ResolveError!bool {
    if (self.conditional_files.get(file)) |known| return known;
    const tree = &self.project.at(file).file.tree;
    const any = for (self.project.at(file).model.declarations) |record| {
        if (record.kind == .parameter and (comptimeBool(tree, record) or comptimeNamed(tree, record))) break true;
    } else false;
    try self.conditional_files.put(self.gpa, file, any);
    return any;
}

/// A condition's value where it is known at compile time on this reading: `true`, `false`, a
/// comptime `bool` parameter the reading's call binds to a known value or the path settles,
/// and `!` of one.
fn truth(self: *const Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ?bool {
    const tree = &self.project.at(file).file.tree;
    const at = switch (conditionOf(tree, node)) {
        .not => |inner| return if (self.truth(env, file, inner)) |t| !t else null,
        .both, .either, .compare => return null,
        .other => |value| if (tree.nodeTag(value) == .identifier) value else return null,
    };
    const spelled = tree.tokenSlice(tree.nodeMainToken(at));
    if (std.mem.eql(u8, spelled, "true")) return true;
    if (std.mem.eql(u8, spelled, "false")) return false;
    const model = &self.project.at(file).model;
    const index = (model.reference(at) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(index)];
    if (record.kind != .parameter) return null;
    if (env) |e| if (file == e.function.file and model.scopes[@backingInt(record.scope)].node == self.scopeNode(e.function)) {
        const position = self.parameterPosition(file, e.function, record.token) orelse return null;
        return if (position < e.truths.len) e.truths[position] else null;
    };
    for (self.assumptions(self.assumed)) |held| if (held.parameter.file == file and held.parameter.index == index) return if (held.value == .boolean) held.value.boolean else null;
    return null;
}

/// A `bool` known as the program compiles, on no call's reading (`comptimeTruth`): `true`,
/// `false`, `!`, `and` and `or` of known ones, two types known the same or different, a
/// `@hasDecl` that resolves; null where it may be either.
pub fn knownBool(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?bool {
    return self.comptimeTruth(null, file, node);
}

/// A condition's form through parentheses and `comptime`: Model's one reading (`Model.conditionOf`).
pub const Condition = Model.Condition;
pub const Comparison = Model.Comparison;
pub const Order = Model.Order;
pub const conditionOf = Model.conditionOf;

/// A part of a condition known to hold a truth value: a comparison or another bool value.
pub const Truth = struct { part: Ast.Node.Index, value: bool };

/// The parts a condition's being `value` shows, each with its truth value, in the order they are
/// written, each read inside its parentheses: `a and b` true shows both true, `a or b` false
/// both false, `!a` shows `a` the other way; `a and b` false or `a or b` true is kept whole,
/// none of its parts shown alone. Null where the condition is known never `value`.
pub fn truthsWhen(self: *Facts, file: Project.FileId, condition: Ast.Node.Index, value: bool) ResolveError!?[]const Truth {
    var out: std.ArrayList(Truth) = .empty;
    if (!try self.gatherTruths(file, condition, value, &out, 0)) return null;
    return out.items;
}

fn gatherTruths(self: *Facts, file: Project.FileId, node: Ast.Node.Index, value: bool, out: *std.ArrayList(Truth), depth: u8) ResolveError!bool {
    // Past the depth, the part is kept whole: true of it, and nothing of its parts.
    if (depth >= 32) {
        try out.append(self.gpa, .{ .part = node, .value = value });
        return true;
    }
    if (try self.knownBool(file, node)) |known| return known == value;
    const condition = conditionOf(&self.project.at(file).file.tree, node);
    switch (condition) {
        .not => |inner| return self.gatherTruths(file, inner, !value, out, depth + 1),
        .both => |sides| if (value) {
            return try self.gatherTruths(file, sides[0], true, out, depth + 1) and try self.gatherTruths(file, sides[1], true, out, depth + 1);
        },
        .either => |sides| if (!value) {
            return try self.gatherTruths(file, sides[0], false, out, depth + 1) and try self.gatherTruths(file, sides[1], false, out, depth + 1);
        },
        .compare, .other => {},
    }
    // A part is the expression inside its parentheses and `comptime` (`(ok)` is `ok`).
    const part = switch (condition) {
        .compare => |compared| compared.node,
        .other => |inner| inner,
        .not, .both, .either => node,
    };
    try out.append(self.gpa, .{ .part = part, .value = value });
    return true;
}

/// A value written in place, by what it is: an enum literal and an error by name, a number, a
/// string, a character, `null`, `undefined`, `true` or `false`, `unreachable`; through
/// parentheses. Null for any other expression (a name, a call), which `resolve` reads.
pub const Literal = union(enum) {
    enum_literal: []const u8,
    error_value: []const u8,
    number,
    string,
    char,
    null,
    undefined,
    boolean: bool,
    @"unreachable",
};

pub fn literalOf(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Literal {
    const tree = &self.project.at(file).file.tree;
    const at = ungrouped(tree, node);
    return switch (tree.nodeTag(at)) {
        .enum_literal => .{ .enum_literal = try Model.identifier(self.gpa, tree.tokenSlice(tree.nodeMainToken(at))) },
        .error_value => .{ .error_value = try Model.identifier(self.gpa, tree.tokenSlice(tree.nodeMainToken(at) + 2)) },
        .number_literal => .number,
        .string_literal, .multiline_string_literal => .string,
        .char_literal => .char,
        .unreachable_literal => .@"unreachable",
        // The language's own values, which no declaration can take.
        .identifier => switch (try self.definition(file, at)) {
            .none => {
                const spelled = tree.tokenSlice(tree.nodeMainToken(at));
                if (std.mem.eql(u8, spelled, "null")) return .null;
                if (std.mem.eql(u8, spelled, "undefined")) return .undefined;
                if (std.mem.eql(u8, spelled, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, spelled, "false")) return .{ .boolean = false };
                return null;
            },
            .decl, .unknown => null,
        },
        else => null,
    };
}

/// A condition known as the program compiles on the reading `env` binds: `truth`'s, `and` and
/// `or` of known ones, `==` and `!=` of two types each side names (`T == Plain`, `namedType`)
/// known the same or different, or of a pointer's known size and a tag (`sizeIs`), and
/// `@hasDecl(T, "name")` where `T` is a container that resolves (a module a driver is built
/// against), its name a string or what the reading binds; `@typeInfo(X) == .tag`;
/// `info.is_tuple` (`isTuple`); and a call to a function returning `bool` whose body decides
/// it (`callTruth`).
fn comptimeTruth(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!?bool {
    const key: TruthKey = .{ .key = .{ .file = file, .node = node }, .env = env, .assumed = self.assumed };
    if (self.truths.get(key)) |kept| return kept;
    // A condition that decides itself (a `bool` function asking itself on the same reading)
    // is not known by its own reading: unknown, and kept by no reading in progress.
    if ((try self.truths_open.getOrPut(self.gpa, key)).found_existing) {
        self.open_met += 1;
        return null;
    }
    defer _ = self.truths_open.remove(key);
    const wide = self.wide;
    const met = self.open_met;
    const answer = try self.comptimeTruthRead(env, file, node);
    // Kept as `resolve` keeps a value: read with budget left and on no answer wider than the built
    // analysis gives (`wideSince`). A known truth holds whatever a query in progress gave inside
    // it: `and`, `or` and `!` know an answer only where the unknown side cannot change it. An
    // unknown is kept only where it met none (`open_met`): one that did is asked again.
    if (self.remaining != 0 and !self.wideSince(wide) and (answer != null or self.open_met == met)) try self.truths.put(self.gpa, key, answer);
    return answer;
}

/// `comptimeTruth`, read.
fn comptimeTruthRead(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!?bool {
    if (self.truth(env, file, node)) |known| return known;
    const tree = &self.project.at(file).file.tree;
    const condition = conditionOf(tree, node);
    const at = switch (condition) {
        .not => |inner| return if (try self.comptimeTruth(env, file, inner)) |known| !known else null,
        .both, .either => |sides| {
            const one = try self.comptimeTruth(env, file, sides[0]);
            const other = try self.comptimeTruth(env, file, sides[1]);
            // Either side alone decides `false and` and `true or`.
            const deciding = condition == .either;
            if (one == deciding or other == deciding) return deciding;
            return if (one != null and other != null) !deciding else null;
        },
        .compare => |compared| {
            if (compared.order != .equal and compared.order != .not_equal) return null;
            // A pointer's size against a tag (`info.size == .slice`).
            if (try self.sizeIs(env, file, compared.left, compared.right) orelse try self.sizeIs(env, file, compared.right, compared.left)) |same_size|
                return if (compared.order == .equal) same_size else !same_size;
            if (try self.kindCompared(env, file, compared.left, compared.right)) |kinds_agree| return if (compared.order == .equal) kinds_agree else !kinds_agree;
            const one = try self.namedType(env, file, compared.left) orelse return null;
            const other = try self.namedType(env, file, compared.right) orelse return null;
            const one_type = sameType(one, other) orelse return null;
            return if (compared.order == .equal) one_type else !one_type;
        },
        .other => |value| value,
    };
    // A `switch` or an `if` giving a `bool`: the branch the bindings take, where they take one.
    if (tree.fullSwitch(at)) |choice| {
        const taken = (try self.takenProng(env, file, choice)) orelse return null;
        if (taken.other != null) return null;
        return self.comptimeTruth(env, file, tree.fullSwitchCase(choice.ast.cases[taken.one]).?.ast.target_expr); // unreachable: a switch's cases are cases
    }
    if (tree.fullIf(at)) |branch| {
        if (branch.payload_token != null or branch.error_token != null) return null;
        const otherwise = branch.ast.else_expr.unwrap() orelse return null;
        const taken = (try self.comptimeTruth(env, file, branch.ast.cond_expr)) orelse return null;
        return self.comptimeTruth(env, file, if (taken) branch.ast.then_expr else otherwise);
    }
    if (try self.isTuple(env, file, at)) |known| return known;
    if (try self.callTruth(env, file, at)) |known| return known;
    if (!isBuiltin(tree, at, "@hasDecl")) return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, at, &buffer);
    if (args.len != 2) return null;
    const container = switch (try self.resolveIn(env, file, args[0])) {
        .container => |c| c,
        else => return null,
    };
    if (container.symbolic) return null;
    const name = try self.nameIn(env, file, args[1], 0) orelse return null;
    const decl = self.project.at(container.file).model.scopes[@backingInt(container.scope)].names.get(name) orelse return false;
    return self.project.at(container.file).model.declarations[@backingInt(decl)].kind != .field;
}

/// Whether the pointer size `size` reads (`info.size`) is the one the enum literal `tag` names
/// (`.slice`). Null where `size` is no pointer's size known, or `tag` no enum literal.
fn sizeIs(self: *Facts, env: ?*const Env, file: Project.FileId, size: Ast.Node.Index, tag: Ast.Node.Index) ResolveError!?bool {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(tag) != .enum_literal) return null;
    const value = try self.resolveIn(env, file, size);
    if (value != .reflected or value.reflected.at != .size or value.reflected.of.* != .pointer) return null;
    const known = value.reflected.of.pointer.size orelse return null;
    return std.mem.eql(u8, try self.memberName(tree.tokenSlice(tree.nodeMainToken(tag))), @tagName(known));
}

/// The type `node` names on the reading `env` binds, where it names one: a container, a
/// primitive type by its name, a `comptime` parameter of type `type` as the reading binds it,
/// `@TypeOf` of a value. Null for a value, whose own value a primitive's would read as.
fn namedType(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var at = node;
    while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
    const value = try self.resolveIn(env, file, at);
    if (value == .container) return value;
    if (value != .primitive) return null;
    switch (tree.nodeTag(at)) {
        .identifier => {
            const reference = model.reference(at) orelse return null;
            const decl = reference.declaration orelse return if (std.zig.primitives.isPrimitive(tree.tokenSlice(tree.nodeMainToken(at)))) value else null;
            const kind = self.parameterTypeNode(.{ .file = file, .index = decl }) orelse return null;
            if (tree.nodeTag(kind) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(kind)), "type")) return null;
            return value;
        },
        .builtin_call_two, .builtin_call_two_comma => return if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(at)), "@TypeOf")) value else null,
        else => return null,
    }
}

/// Whether two types are one: containers by their declaration, primitives by their names, a
/// container never a primitive. Null where it is not known: a symbolic container, or one
/// declaration's containers where a type function made either (`List(u8)` and `List(u16)`).
fn sameType(one: Value, other: Value) ?bool {
    switch (one) {
        .container => |a| switch (other) {
            .container => |b| {
                if (a.symbolic or b.symbolic) return null;
                if (a.file != b.file or a.scope != b.scope) return false;
                return if (a.made_by == null and b.made_by == null) true else null;
            },
            .primitive => return if (a.symbolic) null else false,
            else => return null,
        },
        .primitive => |a| switch (other) {
            .primitive => |b| return std.mem.eql(u8, a, b),
            .container => return sameType(other, one),
            else => return null,
        },
        else => return null,
    }
}

/// Whether `node` may run on the reading `env` binds (a generic's call): no `if` around it
/// within its function takes the other branch on a condition the bindings decide
/// (`comptimeTruth`: `if (T == Plain)`), no `switch` on type information takes another prong
/// (`takenProng`), and no statement before it in a block around it leaves on one
/// (`if (T == Plain) return;`). What the bindings do not decide is reachable, never cleared.
pub fn reachedUnder(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) return true;
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.blockStatements(&buffer, parent)) |statements| {
            for (statements) |statement| {
                if (statement == at) break;
                if (try self.leavesUnder(env, file, statement)) return false;
            }
        } else if (!try self.branchTaken(env, file, parent, at)) return false;
    }
    return true;
}

/// `reachedUnder` for every node one reading of a part reads (`reachAll`): each node decided
/// once, by its parent's answer and the step from the parent to it, a block's statements in
/// one pass. What `cache` holds is the reading's alone.
fn reachedCached(self: *Facts, cache: *std.AutoHashMapUnmanaged(Ast.Node.Index, bool), env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    if (cache.get(node)) |known| return known;
    const tree = &self.project.at(file).file.tree;
    const parent = self.project.at(file).model.parentOf(node) orelse return true;
    const reached = reached: {
        if (tree.nodeTag(parent) == .fn_decl) break :reached true;
        if (!try self.reachedCached(cache, env, file, parent)) break :reached false;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, parent) orelse break :reached try self.branchTaken(env, file, parent, node);
        // A statement after one that leaves on the reading is not reached.
        var left = false;
        for (statements) |statement| {
            try cache.put(self.gpa, statement, !left);
            if (!left) left = try self.leavesUnder(env, file, statement);
        }
        return cache.get(node).?; // unreachable otherwise: a block's child is a statement
    };
    try cache.put(self.gpa, node, reached);
    return reached;
}

/// Whether the reading `env` binds may take the step from `parent` to its child `at`, `parent`
/// no block: an `if` whose condition the bindings decide takes one branch, a `switch` on type
/// information the prongs it takes (`reachedUnder`).
fn branchTaken(self: *Facts, env: ?*const Env, file: Project.FileId, parent: Ast.Node.Index, at: Ast.Node.Index) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    if (tree.fullIf(parent)) |branch| {
        if (branch.payload_token != null or branch.error_token != null or at == branch.ast.cond_expr) return true;
        const taken = try self.comptimeTruth(env, file, branch.ast.cond_expr) orelse return true;
        if (at == branch.ast.then_expr) return taken;
        if (branch.ast.else_expr.unwrap() == at) return !taken;
        return true;
    }
    if (tree.fullSwitch(parent)) |choice| {
        if (at == choice.ast.condition) return true;
        const taken = try self.takenProng(env, file, choice) orelse return true;
        return taken.has(std.mem.findScalar(Ast.Node.Index, choice.ast.cases, at).?); // unreachable: past its condition, a switch's child is a case
    }
    return true;
}

/// Whether a statement never completes on the reading `env` binds: it never does at all
/// (`completesNever`), or it is an `if` whose branch the bindings take never completes.
fn leavesUnder(self: *Facts, env: ?*const Env, file: Project.FileId, statement: Ast.Node.Index) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    if (completesNever(tree, statement)) return true;
    const branch = tree.fullIf(statement) orelse return false;
    if (branch.payload_token != null or branch.error_token != null) return false;
    const taken = try self.comptimeTruth(env, file, branch.ast.cond_expr) orelse return false;
    if (taken) return completesNever(tree, branch.ast.then_expr);
    return completesNever(tree, branch.ast.else_expr.unwrap() orelse return false);
}

/// Whether a branch never completes: a jump or a stop, or a block whose last statement is one.
fn completesNever(tree: *const Ast, node: Ast.Node.Index) bool {
    if (never(tree, node) and tree.nodeTag(node) != .identifier) return true;
    // An `if` neither of whose branches completes.
    if (tree.fullIf(node)) |whole| {
        const otherwise = whole.ast.else_expr.unwrap() orelse return false;
        return completesNever(tree, whole.ast.then_expr) and completesNever(tree, otherwise);
    }
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, node) orelse return false;
    if (statements.len == 0) return false;
    return completesNever(tree, statements[statements.len - 1]);
}

fn boxed(self: *Facts, value: Value) ResolveError!*const Value {
    // The caller gives a scratch arena. Values and memoized facts share its lifetime.
    const box = try self.gpa.create(Value);
    box.* = value;
    return box;
}

fn resolveInner(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    const tag = tree.nodeTag(node);
    switch (tag) {
        .identifier, .test_decl => {
            // A literal no aegis type is: `null`, and the booleans.
            if (tag == .identifier) for ([_][]const u8{ "null", "true", "false" }) |literal| {
                if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), literal)) return .scalar;
            };
            const ref = model.reference(node) orelse return .{ .unknown = .unresolved };
            if (ref.declaration) |decl| return self.declaration(.{ .file = file, .index = decl });
            const name = tree.tokenSlice(ref.token);
            if (Model.primitive(name)) return .{ .primitive = name };
            return .{ .unknown = .unresolved };
        },
        .field_access => return self.fieldValue(file, node),
        .optional_type => return .{ .optional = try self.boxed(try self.resolve(file, tree.nodeData(node).node)) },
        .@"catch", .@"orelse" => return self.unwrapped(null, file, node),
        .unwrap_optional => return self.payload(try self.resolve(file, tree.nodeData(node).node_and_token[0]), .optional),
        .@"switch", .switch_comma, .@"if" => if (try self.branches(null, file, node)) |value| return value,
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            if (try self.breaks(null, file, node)) |value| return value;
            // `{}`: void's one value, as a value of a primitive type is that type.
            var buffer: [2]Ast.Node.Index = undefined;
            if (tree.blockStatements(&buffer, node)) |statements| if (statements.len == 0) return .{ .primitive = "void" };
        },
        .for_simple, .@"for", .while_simple, .while_cont, .@"while" => if (try self.loopValue(file, node)) |value| return value,
        .grouped_expression => return self.resolve(file, tree.nodeData(node).node_and_token[0]),
        // `comptime x` and `nosuspend x` have `x`'s type.
        .@"comptime", .@"nosuspend" => return self.resolve(file, tree.nodeData(node).node),
        // Operators no aegis type takes: Zig has no operator overloading, and every aegis value
        // is a struct or an enum. Their results are numbers or booleans.
        .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .bool_and, .bool_or, .bool_not, .negation, .negation_wrap, .bit_not, .mul, .mul_wrap, .mul_sat, .div, .mod, .shl, .shl_sat, .shr, .bit_and, .bit_or, .bit_xor => return .scalar,
        // `+` and `-` also move many-item pointers: a number only from a number, and a pointer
        // moved by a number is of the pointer's type (`self.metadata.? + idx`). Anything else
        // (a pointer less a pointer) stays unknown.
        .add, .add_wrap, .add_sat, .sub, .sub_wrap, .sub_sat => {
            const operands = tree.nodeData(node).node_and_node;
            const lhs = try self.resolve(file, operands[0]);
            if (lhs == .scalar or lhs == .primitive) return .scalar;
            if (lhs == .pointer and (tree.nodeTag(node) == .add or tree.nodeTag(node) == .sub)) {
                const rhs = try self.resolve(file, operands[1]);
                if (rhs == .scalar or rhs == .primitive) return lhs;
            }
            return .{ .unknown = .unsupported };
        },
        .error_union => return .{ .error_union = try self.boxed(try self.resolve(file, tree.nodeData(node).node_and_node[1])) },
        // An element of an array, a pointer to one, a slice or a many-item pointer.
        .array_access => {
            const operands = tree.nodeData(node).node_and_node;
            const base = try self.resolve(file, operands[0]);
            const held_value = try self.elementOf(base, tree, operands[1]);
            // An element of a constant table of functions: each it holds.
            if (callable(held_value) and !identified(held_value)) return self.identity(held_value, try self.tableElements(file, operands[0]));
            return held_value;
        },
        // A slice of an array is a pointer to the elements (a pointer to an array when the bounds
        // are known, a slice when not: indexed alike); a slice of a slice or pointer is the same.
        .slice_open, .slice, .slice_sentinel => return self.sliced(try self.resolve(file, tree.fullSlice(node).?.ast.sliced), {}),
        // `++` joins arrays: the left side's kind, a string for a literal, and an array of the
        // elements for slices and pointers to arrays, whose lengths are known at compile time.
        .array_cat => {
            const lhs = try self.resolve(file, tree.nodeData(node).node_and_node[0]);
            return switch (lhs) {
                .scalar, .array, .unknown => lhs,
                .pointer => |to| switch (to.child.*) {
                    .array => to.child.*,
                    .unknown => to.child.*,
                    else => .{ .array = to.child },
                },
                else => .{ .unknown = .unsupported },
            };
        },
        .error_set_decl, .merge_error_sets => return .error_set,
        .enum_literal => return self.declarationLiteral(file, node),
        .number_literal, .string_literal, .multiline_string_literal, .char_literal => return .scalar,
        else => {},
    }
    if (try self.typeWritten(file, node)) |value| return value;
    var buffer: [2]Ast.Node.Index = undefined;
    switch (tag) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return self.builtin(null, file, node),
        .call_one, .call_one_comma, .call, .call_comma => return self.callValue(file, node),
        .struct_init_one, .struct_init_one_comma, .struct_init, .struct_init_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init_dot_two, .struct_init_dot_two_comma => {
            const value = tree.fullStructInit(&buffer, node).?;
            if (value.ast.type_expr.unwrap()) |t| return self.instance(try self.resolve(file, t));
            return .{ .literal = .{ .file = file, .node = node } };
        },
        .array_init_one, .array_init_one_comma, .array_init, .array_init_comma => {
            const value = tree.fullArrayInit(&buffer, node).?;
            if (value.ast.type_expr.unwrap()) |t| {
                const typed = try self.resolve(file, t);
                // A table of types (`[_]type{ A, B }`): each element its own, as a tuple's parts.
                if (typed == .array and typed.array.* == .primitive and std.mem.eql(u8, typed.array.primitive, "type")) return .{ .literal = .{ .file = file, .node = node } };
                return self.instance(typed);
            }
            return .{ .unknown = .unsupported };
        },
        // A tuple with no type of its own (`.{ sha2.Sha256, .sha256 }`), as a struct literal is.
        .array_init_dot, .array_init_dot_comma, .array_init_dot_two, .array_init_dot_two_comma => return .{ .literal = .{ .file = file, .node = node } },
        .address_of => return self.pointerTo(try self.resolve(file, tree.nodeData(node).node), .one),
        .deref => return self.pointee(try self.resolve(file, tree.nodeData(node).node), {}),
        .@"try" => return self.payload(try self.resolve(file, tree.nodeData(node).node), .error_union),
        else => return .{ .unknown = .unsupported },
    }
}

/// What the call `node` gives: its callee's result, read with the call's arguments where the
/// callee is a function (a type it is given, a made container's bindings, its body evaluated);
/// each alternative's where it may be several; a function pointer's through what it holds.
fn callValue(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    var call_buffer: [1]Ast.Node.Index = undefined;
    return self.calledValue(file, node, tree.fullCall(&call_buffer, node).?);
}

/// What `call`, the call at `node` (`f(a)`, or `@call`'s callee and tuple), gives.
fn calledValue(self: *Facts, file: Project.FileId, node: Ast.Node.Index, call: Ast.full.Call) ResolveError!Value {
    const callee = try self.resolve(file, call.ast.fn_expr);
    if (callee == .alternatives or callee == .function) if (try self.eachReceiver(file, call)) |value| return value;
    if (callee == .alternatives) return self.map(callee, {}, callResult);
    if (callee == .function) {
        if (try self.typeArgument(file, call, callee.function)) |result| return result;
        // A made container's method read with the container's bindings; where its own
        // generic parameters leave the result unknown, the call's reading of them.
        const made = try self.madeResult(file, call, callee.function);
        if (made) |value| if (!unknownWithin(value)) return value;
        if (try self.evaluateCall(null, file, call, callee.function)) |value| return self.attachMade(value, .{ .function = callee.function, .file = file, .call = node, .assumed = self.assumed });
        if (made) |value| return value;
        var result = try self.callResult(callee, {});
        if (result == .container and result.container.symbolic) {
            result.container.made_by = try self.making(.{ .function = callee.function, .file = file, .call = node, .assumed = self.assumed });
        }
        return result;
    }
    if (try self.throughPointer(file, call.ast.fn_expr)) |value| return value;
    return self.callResult(callee, {});
}

/// A type written in place: a pointer, an array, a function type, a container.
fn typeWritten(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.at(file).file.tree;
    if (tree.fullPtrType(node)) |ptr| return try self.pointerTo(try self.resolve(file, ptr.ast.child_type), ptr.size);
    if (tree.fullArrayType(node)) |array| return .{ .array = try self.boxed(try self.resolve(file, array.ast.elem_type)) };
    var proto_buffer: [1]Ast.Node.Index = undefined;
    if (tree.nodeTag(node) != .fn_decl and tree.fullFnProto(&proto_buffer, node) != null) return .{ .fn_type = .{ .file = file, .node = node } };
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&buffer, node) != null) {
        for (self.project.at(file).model.scopes, 0..) |scope, s| if (scope.kind == .container and scope.node == node) return .{ .container = .{ .file = file, .scope = @fromBackingInt(@intCast(s)) } };
    }
    return null;
}

/// `@field(holder, name)`: by the one name it spells, the member access it means
/// (`@field(L, "acquire")` is `L.acquire`); by a name an inline for ranges over, each member so
/// named, one per pass; over a typeless literal by a name it ranges over or computes, any of its
/// parts. Null where none of these is known.
fn builtinField(self: *Facts, file: Project.FileId, args: []const Ast.Node.Index) ResolveError!?Value {
    switch (try self.fieldName(file, args[1])) {
        .name => |one| return try self.fieldNamed(file, args[0], one),
        // Of a typeless literal, by a name it ranges over or computes (`inline for` over
        // its own `field_names`): any of its parts.
        .each_of, .computed => {
            const resolved = try self.resolve(file, args[0]);
            const held = if (resolved == .pointer) resolved.pointer.child.* else resolved;
            if (held == .literal) return try self.choose(try self.literalParts(held.literal));
        },
        // A name ranging over a list written in place (`inline for (.{ "lin", "length" })
        // |part|`): each member so named, one per pass.
        .names => |names| {
            const resolved = try self.resolve(file, args[0]);
            const held = if (resolved == .pointer) resolved.pointer.child.* else resolved;
            const each = try self.gpa.alloc(Value, names.len);
            if (held == .literal) {
                for (names, each) |one, *out| out.* = try self.literalField(held.literal, one);
                return try self.choose(each);
            }
            const holder = switch (held) {
                .container, .instance => |c| c,
                else => return .{ .unknown = .comptime_dependent },
            };
            if (holder.symbolic and holder.made_by == null) return .{ .unknown = .comptime_dependent };
            for (names, each) |one, *out| out.* = try self.memberOf(holder, self.member(holder, one) orelse return .{ .unknown = .unresolved });
            return try self.choose(each);
        },
    }
    return null;
}

/// The pointer casts that keep what a pointer points at: Zig changes only its alignment,
/// qualifiers or address space, as the result type gives them.
pub const pointee_keeping = [_][]const u8{ "@alignCast", "@constCast", "@volatileCast", "@addrSpaceCast" };

/// What an atomic or a union builtin gives, null for any other: an atomic load's value, or a
/// read-modify-write's old one, what the pointer points at as `p.*` reads it, a value of the type
/// the first argument names where the pointer is none; `@unionInit`'s union, a value of that type;
/// a compare-and-exchange's old value where it fails, null where it succeeds.
fn memoryBuiltin(self: *Facts, env: ?*const Env, file: Project.FileId, name: []const u8, args: []const Ast.Node.Index) ResolveError!?Value {
    for ([_][]const u8{ "@atomicLoad", "@atomicRmw" }) |load| if (args.len >= 2 and std.mem.eql(u8, name, load)) {
        const pointer = try self.resolveIn(env, file, args[1]);
        if (pointer == .pointer or pointer == .alternatives) return try self.pointee(pointer, {});
        return try self.instance(try self.resolveIn(env, file, args[0]));
    };
    if (std.mem.eql(u8, name, "@unionInit") and args.len != 0) return try self.instance(try self.resolveIn(env, file, args[0]));
    for ([_][]const u8{ "@cmpxchgWeak", "@cmpxchgStrong" }) |exchange| if (args.len != 0 and std.mem.eql(u8, name, exchange)) {
        const value = try self.instance(try self.resolveIn(env, file, args[0]));
        if (value == .unknown) return value;
        return .{ .optional = try self.boxed(value) };
    };
    return null;
}

/// What `@import(args)` in `file` gives: the imported Zig file's root container, or the value
/// a ZON file holds; unknown where the name is computed or no mapping gives it.
fn importValue(self: *Facts, file: Project.FileId, args: []const Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) return .{ .unknown = .computed_import };
    const spelling = std.zig.string_literal.parseAlloc(self.gpa, tree.tokenSlice(tree.nodeMainToken(args[0]))) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLiteral => return .{ .unknown = .computed_import },
    };
    var reached: [2]Project.FileId = undefined;
    const targets = self.project.importedAll(file, spelling, &reached);
    if (targets.len == 0) return .{ .unknown = if (self.project.absent(file, spelling))
        .absent
    else if (try self.zigOwn(file, spelling))
        .zig_own
    else
        .missing_mapping };
    // A file both compilations compile, each binding the name apart: either root, as each
    // reads it, a member read in both.
    // A ZON file is a value, never a container: the one expression it holds, read as the same
    // expression written in place is (a struct literal is a `.literal`). By how its tree was
    // parsed: a tree parsed as ZON, and only one, holds that expression at its root.
    const roots = try self.gpa.alloc(Value, targets.len);
    for (targets, roots) |target, *root| root.* = switch (self.project.at(target).file.tree.mode) {
        .zig => .{ .container = self.rootOf(target) },
        // Only a parsed tree has its expression at the root.
        .zon => if (self.project.at(target).file.status != .parsed) .{ .unknown = .invalid_front_end } else try self.resolve(target, self.project.at(target).file.tree.nodeData(.root).node),
    };
    return if (roots.len == 1) roots[0] else self.choose(roots);
}

/// What a builtin call gives: an imported file, `@This()`, a reflected declaration, a type
/// `@as` names, a value's type, a type's information; its operands read with `env`'s
/// bindings where a generic call's reading gives them.
fn builtin(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var buffer: [2]Ast.Node.Index = undefined;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    const args = builtinArgs(tree, node, &buffer);
    if (std.mem.eql(u8, name, "@import")) return self.importValue(file, args);
    // The container the call is in. One a function declares (a type function's `struct`) is
    // the one its reading made: its declaration read in the reading of the function declaring
    // it, as `readBound` attaches its making, so its fields read that reading's bindings.
    if (std.mem.eql(u8, name, "@This")) {
        var scope: ?Model.Scope.Id = model.scopeOf(tree.nodeMainToken(node));
        while (scope) |s| {
            const record = model.scopes[@backingInt(s)];
            if (record.kind == .file) return .{ .container = .{ .file = file, .scope = s } };
            if (record.kind == .container) {
                // The reading that declares it: this one, or one it is read within (a method's
                // reading is within its made container's).
                if (declaredInFunction(model, s)) {
                    var reading = env;
                    while (reading) |r| : (reading = r.outer) {
                        if (self.enclosed(file, s, self.scopeNode(r.function))) return self.resolveIn(r, file, record.node);
                    }
                }
                return .{ .container = .{ .file = file, .scope = s } };
            }
            scope = record.parent;
        }
    }
    if ((std.mem.eql(u8, name, "@field") or std.mem.eql(u8, name, "@hasDecl")) and args.len == 2) {
        // `@hasDecl` is a `bool` whatever it names.
        if (std.mem.eql(u8, name, "@hasDecl")) return .scalar;
        // In a reading, the holder and a name it binds (`hasFn`'s `@field(T, name)`).
        if (env != null) if (try self.nameIn(env, file, args[1], 0)) |known| return self.fieldOf(try self.resolveIn(env, file, args[0]), known);
        if (try self.builtinField(file, args)) |value| return value;
        return .{ .unknown = .comptime_dependent };
    }
    // `@call(modifier, f, .{ a, b })` calls `f` with the tuple's elements, binding no receiver.
    if (std.mem.eql(u8, name, "@call") and args.len == 3) {
        const passed = switch ((try calls.at(self, file, node)).?.args) { // unreachable: a three-operand `@call` is a call
            .known => |each| each,
            .unknown => |why| return .{ .unknown = why },
        };
        return self.calledValue(file, node, .{ .ast = .{ .lparen = tree.nodeMainToken(node), .fn_expr = args[1], .params = passed } });
    }
    if (std.mem.eql(u8, name, "@as") and args.len == 2) {
        const named = try self.resolveIn(env, file, args[0]);
        // A type, or types, held as a value: what they are is the operand.
        if (holdsTypes(named)) return self.resolveIn(env, file, args[1]);
        return self.instance(named);
    }
    if (try self.memoryBuiltin(env, file, name, args)) |value| return value;
    // Every element the operand: an array of it (a vector is indexed as one).
    if (std.mem.eql(u8, name, "@splat") and args.len == 1) return .{ .array = try self.boxed(try self.resolveIn(env, file, args[0])) };
    // A pointer cast that keeps what it points at: Zig changes only the pointer's alignment,
    // qualifiers or address space, which the result type gives, never its pointee.
    for (pointee_keeping) |cast| if (std.mem.eql(u8, name, cast) and args.len == 1) return self.resolveIn(env, file, args[0]);
    // A type built from its fields' types: `@Struct(layout, backing, names, types, attributes)`,
    // `@Union(layout, tag, names, types, attributes)`, `@Tuple(types)`.
    if ((std.mem.eql(u8, name, "@Struct") or std.mem.eql(u8, name, "@Union")) and args.len == 5) return self.reified(try self.resolveIn(env, file, args[3]));
    if (std.mem.eql(u8, name, "@Tuple") and args.len == 1) return self.reified(try self.resolveIn(env, file, args[0]));
    // `@Pointer(size, attributes, child, sentinel)`: a pointer to `child` of the size it names.
    if (std.mem.eql(u8, name, "@Pointer") and args.len == 4) {
        const child = try self.resolveIn(env, file, args[2]);
        if (child == .unknown) return child;
        return self.pointerTo(child, try self.sizeNamed(env, file, args[0]));
    }
    // A vector is indexed as an array of its lanes, and holds only numbers, truth values and
    // pointers.
    if (std.mem.eql(u8, name, "@Vector") and args.len == 2) return .{ .array = try self.boxed(try self.resolveIn(env, file, args[1])) };
    // An integer type of a signedness and width computed at compile time: a number, whose width
    // nothing here reads.
    if (std.mem.eql(u8, name, "@Int")) return .{ .primitive = "@Int" };
    // An enum type built from names and values: it holds no value but its tag.
    if (std.mem.eql(u8, name, "@Enum")) return .{ .primitive = "@Enum" };
    if (std.mem.eql(u8, name, "@FieldType") and args.len == 2) return self.fieldType(try self.resolveIn(env, file, args[0]), try self.nameIn(env, file, args[1], 0));
    if (std.mem.eql(u8, name, "@TypeOf") and args.len == 1) return self.map(try self.resolveIn(env, file, args[0]), {}, typeOf);
    // `@call(modifier, f, args)`: what calling `f` gives, as its result type reads.
    if (std.mem.eql(u8, name, "@call") and args.len == 3) {
        const callee = try self.resolveIn(env, file, args[1]);
        if (callee == .alternatives) return self.map(callee, {}, callResult);
        return self.callResult(callee, {});
    }
    if (std.mem.eql(u8, name, "@typeInfo") and args.len == 1) return self.reflect(try self.resolveIn(env, file, args[0]));
    // A name's bytes: `[:0]const u8`, or the file's bytes for `@embedFile`.
    // `[:0]const u8`; `@embedFile`'s is a pointer to one array of them.
    for ([_][]const u8{ "@errorName", "@tagName", "@typeName" }) |bytes| if (std.mem.eql(u8, name, bytes)) return self.pointerTo(.{ .primitive = "u8" }, .slice);
    if (std.mem.eql(u8, name, "@embedFile")) return self.pointerTo(.{ .array = try self.boxed(.{ .primitive = "u8" }) }, .one);
    // A number or a truth value, whatever the arguments are.
    for (numeric_builtins) |number| if (std.mem.eql(u8, name, number)) return .scalar;
    // Values of std's own types, as the language gives them.
    if (std.mem.eql(u8, name, "@errorReturnTrace")) {
        const trace = try self.stdMember(&.{ "builtin", "StackTrace" });
        if (trace == .unknown) return trace;
        return .{ .optional = try self.boxed(try self.pointerTo(try self.instance(trace), .one)) };
    }
    if (std.mem.eql(u8, name, "@src")) return self.instance(try self.stdMember(&.{ "builtin", "SourceLocation" }));
    return .{ .unknown = .comptime_dependent };
}

/// Whether a value is type information (`@typeInfo(T)`), or a choice of it.
fn reflectedInfo(value: Value) bool {
    const each: []const Value = if (value == .alternatives) value.alternatives else &.{value};
    for (each) |one| if (one != .reflected or one.reflected.at != .info) return false;
    return true;
}

/// Whether a value is unknown, itself or what a pointer, optional, error union or array holds.
fn unknownWithin(value: Value) bool {
    return switch (value) {
        .unknown => true,
        .pointer => |inner| unknownWithin(inner.child.*),
        .optional, .error_union, .array => |inner| unknownWithin(inner.*),
        else => false,
    };
}

/// A declaration of std's by its path from std's root (`builtin.StackTrace`), where the
/// project maps std.
fn stdMember(self: *Facts, path: []const []const u8) ResolveError!Value {
    const root = for (self.project.imports) |mapping| {
        if (std.mem.eql(u8, mapping.spelling, "std")) break mapping.target;
    } else return .{ .unknown = .missing_mapping };
    var value: Value = .{ .container = self.rootOf(root) };
    for (path) |name| value = try self.memberValue(value, name);
    return value;
}

/// Whether the type written at `node` is `type` itself, by what it resolves to: `comptime
/// T: type`, a function returning `type`, `const Kind = type;` named for it.
pub fn typeIsType(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    const value = try self.resolve(file, node);
    return value == .primitive and std.mem.eql(u8, value.primitive, "type");
}

/// Whether a declared type holds types as values: `type`, `[N]type`, `[]const type`, `?type`.
fn holdsTypes(value: Value) bool {
    return switch (value) {
        .primitive => |name| std.mem.eql(u8, name, "type"),
        .pointer => |inner| holdsTypes(inner.child.*),
        .array, .optional => |inner| holdsTypes(inner.*),
        else => false,
    };
}

/// A type built from `types`, a list of its fields' types (an array of them, a pointer to one,
/// or a tuple literal of them): one that holds what they do.
fn reified(self: *Facts, types: Value) ResolveError!Value {
    const each: Value = switch (types) {
        .pointer => |inner| return self.reified(inner.child.*),
        .array => |inner| inner.*,
        .literal => |literal| blk: {
            const parts = try self.literalParts(literal);
            if (parts.len == 0) return .{ .unknown = .unsupported };
            break :blk try self.choose(parts);
        },
        .alternatives => return self.map(types, {}, reifiedEach),
        .unknown => return types,
        else => return .{ .unknown = .unsupported },
    };
    if (each == .unknown) return each;
    return .{ .reified = .{ .fields = try self.boxed(each) } };
}
fn reifiedEach(self: *Facts, types: Value, _: void) ResolveError!Value {
    return self.reified(types);
}

/// `@FieldType(T, name)`: the type of `T`'s field `name`; for a name computed at compile
/// time, one of its fields' types, each a choice.
fn fieldType(self: *Facts, of: Value, field_name: ?[]const u8) ResolveError!Value {
    const container = switch (of) {
        .container => |c| c,
        .unknown => |why| return .{ .unknown = why },
        else => return .{ .unknown = .unsupported },
    };
    // A container a type function makes has its fields' types where the call that made it is
    // known, read with that call's bindings.
    if (container.symbolic and container.made_by == null) return .{ .unknown = .comptime_dependent };
    if (field_name) |name| {
        const field = self.member(container, name) orelse return .{ .unknown = .unresolved };
        return typeOf(self, try self.memberOf(container, field), {});
    }
    return self.fieldTypes(container);
}

/// The name a comptime expression spells, read with `env`'s bindings: a string literal, an
/// enum literal's name, `@tagName` of one, or a parameter whose argument, where it is written,
/// spells one. Null where none is known.
fn nameIn(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index, depth: usize) ResolveError!?[]const u8 {
    if (depth == 8) return null;
    const tree = &self.project.at(file).file.tree;
    switch (tree.nodeTag(node)) {
        .string_literal => return std.zig.string_literal.parseAlloc(self.gpa, tree.tokenSlice(tree.nodeMainToken(node))) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        },
        .enum_literal => return try self.memberName(tree.tokenSlice(tree.nodeMainToken(node))),
        .grouped_expression => return self.nameIn(env, file, tree.nodeData(node).node_and_token[0], depth + 1),
        .@"comptime" => return self.nameIn(env, file, tree.nodeData(node).node, depth + 1),
        // Two names joined as the program compiles (`"Key" ++ "Pair"`).
        .array_cat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = (try self.nameIn(env, file, lhs, depth + 1)) orelse return null;
            const right = (try self.nameIn(env, file, rhs, depth + 1)) orelse return null;
            return try std.mem.concat(self.gpa, u8, &.{ left, right });
        },
        .builtin_call_two, .builtin_call_two_comma => {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@tagName")) return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = builtinArgs(tree, node, &buffer);
            if (args.len != 1) return null;
            return self.nameIn(env, file, args[0], depth + 1);
        },
        .identifier => {},
        else => return null,
    }
    const model = &self.project.at(file).model;
    const index = (model.reference(node) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(index)];
    // A `const` that holds a name (`const field_name = "bytes"`) spells it.
    if (record.kind == .variable) {
        const variable = tree.fullVarDecl(record.node) orelse return null;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
        return self.nameIn(env, file, variable.ast.init_node.unwrap() orelse return null, depth + 1);
    }
    if (record.kind != .parameter) return null;
    var at: ?*const Env = env;
    while (at) |reading| : (at = reading.outer) {
        if (reading.function.file != file or model.scopes[@backingInt(record.scope)].node != self.scopeNode(reading.function)) continue;
        const position = self.parameterPosition(file, reading.function, record.token) orelse return null;
        if (position >= reading.spelled.len) return null;
        const spelled = reading.spelled[position] orelse return null;
        return if (spelled == .name) spelled.name else null;
    }
    return null;
}

/// What `@field`'s name names: the one name it spells (a string literal with its escapes read,
/// a `const` that holds one, an enum literal, `@tagName` of one), each field of a struct whose
/// `field_names` it ranges over, each name of a list written in place it ranges over
/// (`inline for (.{ "a", "b" }) |name|`), or a name it computes, not known here.
pub const FieldName = union(enum) { name: []const u8, each_of: Container, names: []const []const u8, computed };
pub fn fieldName(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!FieldName {
    if (try self.nameIn(null, file, node, 0)) |name| return .{ .name = name };
    if (try self.fieldNamesOf(file, node)) |container| return .{ .each_of = container };
    if (try self.rangedNames(file, node)) |names| return .{ .names = names };
    return .computed;
}

/// The const a name refers to, and the expression it is given, in its own file: what an error
/// name or set spelled through a const is read as. Null for anything else.
fn constantValue(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?struct { Project.FileId, Ast.Node.Index } {
    const decl = switch (try self.definition(file, node)) {
        .decl => |d| d,
        .none, .unknown => return null,
    };
    const source = self.project.at(decl.file);
    const record = source.model.declarations[@backingInt(decl.index)];
    if (record.kind != .variable) return null;
    const variable = source.file.tree.fullVarDecl(record.node) orelse return null;
    if (source.file.tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
    return .{ decl.file, variable.ast.init_node.unwrap() orelse return null };
}

/// The error an expression names: `error.Name`, a member of an error set (`Set.Name`), or a
/// const given one; null where it names none, or one not shown here.
pub fn errorName(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?[]const u8 {
    var at_file = file;
    var at = node;
    for (0..16) |_| {
        const tree = &self.project.at(at_file).file.tree;
        at = ungrouped(tree, at);
        switch (tree.nodeTag(at)) {
            .error_value => return try Model.identifier(self.gpa, tree.tokenSlice(tree.nodeMainToken(at) + 2)),
            .field_access => {
                const holder, const name = tree.nodeData(at).node_and_token;
                if (try self.resolve(at_file, holder) == .error_set) return try Model.identifier(self.gpa, tree.tokenSlice(name));
            },
            else => {},
        }
        at_file, at = (try self.constantValue(at_file, at)) orelse return null;
    }
    return null;
}

/// Whether the error set a type names holds the error `name`: an `error{...}` set, `A || B`,
/// an error union's set, `anyerror` (every error), or a const given one. Unknown where the set
/// is not written here (an inferred `!T`, one a function or `@TypeOf` makes, a name that does
/// not resolve), never read as either.
pub fn errorSetHolds(self: *Facts, file: Project.FileId, node: Ast.Node.Index, name: []const u8) ResolveError!Is {
    return self.setHolds(file, node, name, 0);
}

fn setHolds(self: *Facts, file: Project.FileId, node: Ast.Node.Index, name: []const u8, depth: u8) ResolveError!Is {
    if (depth >= 16) return .{ .unknown = .budget };
    const tree = &self.project.at(file).file.tree;
    const at = ungrouped(tree, node);
    switch (tree.nodeTag(at)) {
        .error_set_decl => {
            const open, const close = tree.nodeData(at).token_and_token;
            var token = open + 1;
            while (token < close) : (token += 1) {
                if (tree.tokenTag(token) != .identifier) continue;
                if (std.mem.eql(u8, try Model.identifier(self.gpa, tree.tokenSlice(token)), name)) return .yes;
            }
            return .no;
        },
        .merge_error_sets => {
            const lhs, const rhs = tree.nodeData(at).node_and_node;
            const left = try self.setHolds(file, lhs, name, depth + 1);
            if (left == .yes) return .yes;
            const right = try self.setHolds(file, rhs, name, depth + 1);
            if (right == .yes) return .yes;
            if (left == .no and right == .no) return .no;
            return if (left == .unknown) left else right;
        },
        .error_union => return self.setHolds(file, tree.nodeData(at).node_and_node[0], name, depth + 1),
        .identifier => if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(at)), "anyerror") and try self.definition(file, at) == .none) return .yes,
        else => {},
    }
    const given_file, const given = (try self.constantValue(file, at)) orelse return .{ .unknown = .unsupported };
    return self.setHolds(given_file, given, name, depth + 1);
}

/// The errors a function's prototype says it returns: none (no error union), a set written
/// there or in a const its result names (`E!T`, the set's node and file), inferred (`!T`), which
/// the body decides, or unknown: an error union the result names in a way not read here.
pub const Returned = union(enum) { none, set: struct { file: Project.FileId, node: Ast.Node.Index }, inferred, unknown: Unknown };

pub fn returnedErrors(self: *Facts, file: Project.FileId, proto: Ast.full.FnProto) ResolveError!Returned {
    const tree = &self.project.at(file).file.tree;
    const result = proto.ast.return_type.unwrap() orelse return .none;
    if (tree.tokenTag(tree.firstToken(result) - 1) == .bang) return .inferred;
    var at_file = file;
    var at = result;
    for (0..16) |_| {
        const source = &self.project.at(at_file).file.tree;
        at = ungrouped(source, at);
        if (source.nodeTag(at) == .error_union) return .{ .set = .{ .file = at_file, .node = source.nodeData(at).node_and_node[0] } };
        at_file, at = (try self.constantValue(at_file, at)) orelse break;
    }
    return switch (try self.resolve(file, result)) {
        .error_union => .{ .unknown = .unsupported },
        .unknown => |why| .{ .unknown = why },
        else => .none,
    };
}

/// The names a capture takes from a list written in place that a `for` ranges over alone, each
/// element one name spells (`nameIn`); null where one does not.
fn rangedNames(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?[]const []const u8 {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    if (tree.nodeTag(node) != .identifier) return null;
    const decl = (model.reference(node) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(decl)];
    if (record.kind != .capture) return null;
    var at = record.node;
    const loop = while (true) {
        if (tree.fullFor(at)) |found| break found;
        at = model.parentOf(at) orelse return null;
    };
    // The input the capture takes, of several (`inline for (.{ "a", "b" }, 0..) |name, i|`).
    const position = Model.capturePosition(tree, loop, record.token) orelse return null;
    if (position >= loop.ast.inputs.len) return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const list = tree.fullArrayInit(&buffer, loop.ast.inputs[position]) orelse return null;
    var names: std.ArrayList([]const u8) = .empty;
    for (list.ast.elements) |item| try names.append(self.gpa, (try self.nameIn(null, file, item, 0)) orelse return null);
    return names.items;
}
/// Whether a `@field` name may be `name`: it spells it, or ranges over a struct that has it or
/// a list that names it.
pub fn mayName(self: *Facts, field_name: FieldName, name: []const u8) bool {
    return switch (field_name) {
        .name => |spelled| std.mem.eql(u8, spelled, name),
        .each_of => |container| self.hasField(container, name),
        .names => |each| for (each) |one| {
            if (std.mem.eql(u8, one, name)) break true;
        } else false,
        .computed => true,
    };
}

/// The type of any of a container's fields, the choice of them: what `@FieldType` gives for a
/// name not known here, and `field_types` of its type information.
fn fieldTypes(self: *Facts, container: Container) ResolveError!Value {
    if (container.symbolic and container.made_by == null) return .{ .unknown = .comptime_dependent };
    const model = &self.project.at(container.file).model;
    var each: std.ArrayList(Value) = .empty;
    for (model.declarations, 0..) |d, i| {
        if (d.kind != .field or d.scope != container.scope) continue;
        const field = model.containerField(self.syntaxOf(container.file), d.node) orelse continue;
        if (field.ast.type_expr == .none) continue;
        try each.append(self.gpa, try typeOf(self, try self.memberOf(container, .{ .file = container.file, .index = @fromBackingInt(@intCast(i)) }), {}));
    }
    if (each.items.len == 0) return .{ .unknown = .unsupported };
    return self.choose(each.items);
}

/// A field an instance holds: what `memberOf` reads it as, and its declaration, null for a
/// tuple's, which declares none.
pub const HeldField = struct { value: Value, decl: ?Decl };

/// Each field an instance of `container` holds by value: a named one as `memberOf` reads it,
/// then a tuple's (`struct { Key, u8 }`) by its type, with a made container's bindings.
pub fn heldFields(self: *Facts, container: Container) ResolveError![]const HeldField {
    const model = &self.project.at(container.file).model;
    const tree = self.syntaxOf(container.file);
    var out: std.ArrayList(HeldField) = .empty;
    // An enum's value is its tag, an integer: it holds no field.
    if (self.kindOf(container) == .keyword_enum) return out.items;
    for (model.declarations, 0..) |d, i| {
        if (d.kind != .field or d.scope != container.scope) continue;
        const decl: Decl = .{ .file = container.file, .index = @fromBackingInt(@intCast(i)) };
        try out.append(self.gpa, .{ .value = try self.memberOf(container, decl), .decl = decl });
    }
    const node = model.scopes[@backingInt(container.scope)].node;
    if (node == .root) return out.items;
    var buffer: [2]Ast.Node.Index = undefined;
    const full = tree.fullContainerDecl(&buffer, node) orelse return out.items;
    for (full.ast.members) |item| {
        const field = model.containerField(tree, item) orelse continue;
        if (!field.ast.tuple_like) continue;
        const type_node = field.ast.type_expr.unwrap() orelse continue;
        const value = if (container.made_by) |made| blk: {
            const bound = try self.substituted(container.file, type_node, made);
            break :blk if (bound == .unknown) bound else try self.valueOf(try self.madeWithin(bound, container, made));
        } else try self.instance(try self.resolve(container.file, type_node));
        try out.append(self.gpa, .{ .value = value, .decl = null });
    }
    return out.items;
}

const AddressFree = struct {
    /// A container read without a type function's bindings, by its declaration; one in
    /// progress is read as one that may hold an address.
    found: std.AutoHashMapUnmanaged(struct { Project.FileId, Model.Scope.Id }, ?bool) = .empty,
};

/// Whether a value of type `value`, or a value `value` is, holds no address anywhere: a number,
/// a truth value, an error, an enum's tag, and arrays, optionals and error unions of one, and a
/// struct or a union whose every field holds none (`heldFields`). A pointer, a function, an
/// opaque, a container a field of which may hold one, a type not known may hold one.
pub fn holdsNoAddress(self: *Facts, value: Value) ResolveError!bool {
    return switch (value) {
        .primitive, .scalar, .error_set => true,
        .array, .optional, .error_union => |inner| self.holdsNoAddress(inner.*),
        .alternatives => |each| for (each) |one| {
            if (!try self.holdsNoAddress(one)) break false;
        } else true,
        .container, .instance => |container| self.containerHoldsNoAddress(container),
        else => false,
    };
}

fn containerHoldsNoAddress(self: *Facts, container: Container) ResolveError!bool {
    if (container.symbolic and container.made_by == null) return false;
    switch (self.kindOf(container) orelse return false) {
        .keyword_enum => return true,
        .keyword_struct, .keyword_union => {},
        else => return false,
    }
    const free = try self.memo(AddressFree);
    const key = .{ container.file, container.scope };
    if (container.made_by == null) {
        if (free.found.get(key)) |kept| return kept orelse false;
        try free.found.put(self.gpa, key, null);
    }
    var out = true;
    for (try self.heldFields(container)) |field| if (!try self.holdsNoAddress(field.value)) {
        out = false;
        break;
    };
    if (container.made_by == null) try free.found.put(self.gpa, key, out);
    return out;
}

/// Each part a value holds by value, for a rule to judge one by one: an instance or a type
/// (`container`), each field it holds (`heldFields`) in turn, a pointer (not what it points to),
/// and what does not resolve; through an error union, an optional, an array, a choice of types,
/// a literal's parts and a type built from its fields' types (`@Struct`), what they wrap. A
/// record of std's no type function made holds none of the program's types (std imports none
/// of them): its fields are not read.
/// The list is on `allocator`, the caller's: a rule's is its file's memory.
pub fn heldParts(self: *Facts, allocator: std.mem.Allocator, value: Value) ResolveError![]const Value {
    var out: std.ArrayList(Value) = .empty;
    try self.collectHeld(allocator, &out, value, 0);
    return out.items;
}

fn collectHeld(self: *Facts, allocator: std.mem.Allocator, out: *std.ArrayList(Value), value: Value, depth: u8) ResolveError!void {
    if (depth == 16) return out.append(allocator, .{ .unknown = .cycle });
    switch (value) {
        .instance, .container => |found| {
            try out.append(allocator, value);
            if (found.made_by == null and try self.standard(found.file)) return;
            for (try self.heldFields(found)) |field| try self.collectHeld(allocator, out, field.value, depth + 1);
        },
        .error_union, .optional, .array => |inner| try self.collectHeld(allocator, out, inner.*, depth + 1),
        .alternatives => |each| for (each) |one| try self.collectHeld(allocator, out, one, depth + 1),
        .literal => |key| for (try self.literalParts(key)) |one| try self.collectHeld(allocator, out, one, depth + 1),
        .reified => |built| try self.collectHeld(allocator, out, try self.reifiedParts(built), depth + 1),
        .pointer, .unknown => try out.append(allocator, value),
        else => {},
    }
}

/// Builtins whose result is a number or a truth value: sizes and offsets, conversions to
/// integers, bit counts, arithmetic and the queries that answer yes or no.
const numeric_builtins = [_][]const u8{
    "@sizeOf",       "@alignOf",       "@bitSizeOf",    "@offsetOf",     "@bitOffsetOf", "@intFromPtr", "@intFromBool", "@intFromEnum",
    "@intFromError", "@intFromFloat",  "@clz",          "@ctz",          "@popCount",    "@byteSwap",   "@bitReverse",  "@divExact",
    "@divFloor",     "@divTrunc",      "@mod",          "@rem",          "@shlExact",    "@shrExact",   "@min",         "@max",
    "@abs",          "@sqrt",          "@floor",        "@ceil",         "@trunc",       "@round",      "@hasDecl",     "@hasField",
    "@inComptime",   "@returnAddress", "@frameAddress", "@floatFromInt", "@mulAdd",      "@sin",        "@cos",         "@exp",
    // An enum's or a packed struct's backing integer.
    "@backingInt",
};

fn memberValue(self: *Facts, lhs: Value, name: []const u8) ResolveError!Value {
    if (lhs == .reflected) return self.reflectedMember(lhs.reflected, name);
    if (lhs == .literal) return self.literalField(lhs.literal, name);
    if (lhs == .pointer and lhs.pointer.child.* == .literal) return self.literalField(lhs.pointer.child.literal, name);
    if (lhs == .pointer and lhs.pointer.child.* == .alternatives) return self.memberOfChoice(lhs.pointer.child.alternatives, name);
    if (lhs == .alternatives) return self.memberOfChoice(lhs.alternatives, name);
    const container = switch (lhs) {
        .container, .instance => |c| c,
        .pointer => |p| switch (p.child.*) {
            .instance, .container => |c| if (self.member(c, name)) |decl| return self.memberOf(c, decl) else return sequence(lhs, name),
            .alternatives => return self.map(p.child.*, name, memberValue),
            else => return sequence(lhs, name),
        },
        // An array's one member is its length, a number.
        .array => return if (std.mem.eql(u8, name, "len")) .scalar else .{ .unknown = .unresolved },
        .unknown => return lhs,
        else => return .{ .unknown = .unresolved },
    };
    // A tag named on an enum or a union type (`Color.red`, `Shape.empty`): a value of it.
    if (lhs == .container and self.declaresTag(container, name)) return .{ .instance = container };
    if (self.member(container, name)) |decl| return self.memberOf(container, decl);
    return .{ .unknown = .unresolved };
}

/// A tag of an enum or a union, by its type and its name.
pub const Tag = struct { container: Container, name: []const u8 };

/// The tag a value names: an enum literal by the type its place gives it (`.unlimited` given a
/// limit), a tag named on its type (`Io.Limit.unlimited`), a constant that names one. Null where
/// it names none, or its type does not resolve.
pub fn tagNamed(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Tag {
    return self.tagWithin(file, node, 0);
}

fn tagWithin(self: *Facts, file: Project.FileId, node: Ast.Node.Index, depth: u8) ResolveError!?Tag {
    const tree = &self.project.at(file).file.tree;
    switch (tree.nodeTag(node)) {
        .enum_literal => {
            const name = try self.memberName(tree.tokenSlice(tree.nodeMainToken(node)));
            var holder = try self.literalType(file, node);
            while (true) holder = switch (holder) {
                .pointer => |inner| inner.child.*,
                .optional, .error_union => |inner| inner.*,
                else => break,
            };
            const container = switch (holder) {
                .container, .instance => |k| k,
                else => return null,
            };
            return if (self.declaresTag(container, name)) .{ .container = container, .name = name } else null;
        },
        .field_access => {
            const lhs, const token = tree.nodeData(node).node_and_token;
            const container = switch (try self.resolve(file, lhs)) {
                .container => |k| k,
                else => return null,
            };
            const name = try self.memberName(tree.tokenSlice(token));
            return if (self.declaresTag(container, name)) .{ .container = container, .name = name } else null;
        },
        .identifier => {
            if (depth > 4) return null;
            const decl = switch (try self.definition(file, node)) {
                .decl => |d| d,
                else => return null,
            };
            const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
            if (record.kind != .variable) return null;
            const held = &self.project.at(decl.file).file.tree;
            const constant = held.fullVarDecl(record.node) orelse return null;
            if (held.tokenTag(constant.ast.mut_token) != .keyword_const) return null;
            return self.tagWithin(decl.file, constant.ast.init_node.unwrap() orelse return null, depth + 1);
        },
        else => return null,
    }
}

/// Whether `container` is an `enum` or a `union` with a field `name`, one of its tags.
pub fn declaresTag(self: *const Facts, container: Container, name: []const u8) bool {
    switch (self.kindOf(container) orelse return false) {
        .keyword_enum, .keyword_union => {},
        else => return false,
    }
    const decl = self.member(container, name) orelse return false;
    return self.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind == .field;
}

/// Whether a container written in the program declares no member `name`.
fn lacks(self: *const Facts, container: Container, name: []const u8) bool {
    return !container.symbolic and self.member(container, name) == null;
}

/// A field of an anonymous struct literal: the value the literal gives it.
fn literalField(self: *Facts, literal: Key, name: []const u8) ResolveError!Value {
    const tree = &self.project.at(literal.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const full = tree.fullStructInit(&buffer, literal.node) orelse return .{ .unknown = .unsupported };
    for (full.ast.fields) |field| {
        const label = try self.memberName(tree.tokenSlice(Model.initName(tree, field) orelse continue));
        if (std.mem.eql(u8, label, name)) return self.resolve(literal.file, field);
    }
    return .{ .unknown = .unresolved };
}

/// A member of one of several types chosen at compile time: a choice without members (`void`,
/// a number) is a build in which this access does not compile, so it is left out.
fn memberOfChoice(self: *Facts, choices: []const Value, name: []const u8) ResolveError!Value {
    var kept: std.ArrayList(Value) = .empty;
    for (choices) |choice| switch (choice) {
        .primitive, .scalar => continue,
        // An optional or error union has no member a name reads, and an array only its length:
        // the choice that holds one is another.
        .optional, .error_union => continue,
        .array => if (!std.mem.eql(u8, name, "len")) continue else try kept.append(self.gpa, try self.memberValue(choice, name)),
        // A type that declares no such member, likewise.
        .container, .instance => |c| if (self.lacks(c, name)) continue else try kept.append(self.gpa, try self.memberValue(choice, name)),
        .pointer => |to| switch (to.child.*) {
            .container, .instance => |c| if (self.lacks(c, name)) continue else try kept.append(self.gpa, try self.memberValue(choice, name)),
            else => try kept.append(self.gpa, try self.memberValue(choice, name)),
        },
        else => try kept.append(self.gpa, try self.memberValue(choice, name)),
    };
    if (kept.items.len == 0) return .{ .unknown = .unresolved };
    return self.choose(kept.items);
}

/// What the member `decl` of `container` holds: a field's value, read with the bindings of
/// the call that made the container, if any.
pub fn memberField(self: *Facts, container: Container, decl: Decl) ResolveError!Value {
    return self.memberOf(container, decl);
}

/// A member of `container`: a field of a container a type function made is of its declared
/// type with the function's parameters read as the call's arguments, and a container declared
/// inside the made one is made by the same call.
pub fn memberOf(self: *Facts, container: Container, decl: Decl) ResolveError!Value {
    const made = container.made_by orelse return self.declaration(decl);
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    const tree = &self.project.at(decl.file).file.tree;
    // A type it declares (`Replay`, `Record`) is made by the same call; a declaration naming
    // one made elsewhere (`const Record = State.Record;`) is read with the call's bindings, as
    // a field's type is, the template's reading standing where that reading is unknown.
    if (record.kind != .field) {
        // One typed `type` (`pub const Key: type = E;`) names a type as an untyped one does.
        if (record.kind == .variable) if (tree.fullVarDecl(record.node)) |variable| if (variable.ast.type_node == .none or namesType(tree, variable.ast.type_node.unwrap().?)) if (variable.ast.init_node.unwrap()) |init| {
            const value = try self.substituted(decl.file, init, made);
            if (value != .unknown) return self.madeWithin(value, container, made);
        };
        return self.madeWithin(try self.declaration(decl), container, made);
    }
    const field = self.project.at(decl.file).model.containerField(tree, record.node) orelse return self.declaration(decl);
    const type_node = field.ast.type_expr.unwrap() orelse return self.declaration(decl);
    const value = try self.substituted(decl.file, type_node, made);
    if (value == .unknown) {
        // The template's reading is what every instantiation makes of the field; it stands for
        // this one only where they agree.
        const template_value = try self.declaration(decl);
        return if (template_value == .alternatives) value else template_value;
    }
    return self.valueOf(try self.madeWithin(value, container, made));
}

/// Whether a type expression is `type`.
fn namesType(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "type");
}

/// A member read through a value (`x.name`). Called through a field that holds a function
/// pointer (`p.writeUsage(w)`, `w.vtable.drain(…)`), the functions stored there, where every
/// store is seen.
fn fieldValue(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const data = tree.nodeData(node).node_and_token;
    return self.fieldNamed(file, data[0], try self.memberName(tree.tokenSlice(data[1])));
}

/// What `holder.name` is, written as a member access or as `@field(holder, "name")`.
fn fieldNamed(self: *Facts, file: Project.FileId, holder: Ast.Node.Index, name: []const u8) ResolveError!Value {
    return self.fieldOf(try self.resolve(file, holder), name);
}

/// What `name` read off `lhs` is (`fieldNamed`), the holder already read.
fn fieldOf(self: *Facts, lhs: Value, name: []const u8) ResolveError!Value {
    const value = try self.memberValue(lhs, name);
    // A field holding a function or a pointer to one: each function the program stores in it.
    if (callable(value) and !identified(value)) if (fieldOwner(lhs)) |container| {
        const stored = (try self.storedFunctions(container, name)) orelse return self.erased(value);
        return self.identity(value, &.{stored});
    };
    return value;
}

/// Whether `node` is what a call calls.
fn called(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    const parent = model.parentOf(node) orelse return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, parent) orelse return false;
    return call.ast.fn_expr == node;
}

/// The struct whose field a value read through `lhs` is: a value of it, or a pointer to one.
fn fieldOwner(lhs: Value) ?Container {
    return switch (lhs) {
        .instance => |c| c,
        .pointer => |to| switch (to.child.*) {
            .instance => |c| c,
            else => null,
        },
        else => null,
    };
}

/// The functions the program stores in `container`'s field `name`, a function pointer: one, or a
/// choice of them, each a call through the field may reach. A store is the field's default
/// value, a struct literal's value for it, or an assignment to it, in every file the program
/// holds, dependencies and std among them; a literal or an object whose type does not resolve
/// counts as one of the field's where it names it. Null, the call left unresolved, where a
/// store may go unseen: a value that is not a function the program declares (a parameter, a
/// field's, a cast's, `undefined`), the field's address taken or written through `@field`, a
/// value of the struct made by a cast or declared `extern`, a file the front end refused, or an
/// `@import` of a file the program does not hold. Only the files that may share a compilation
/// with the struct's (`compiledWith`) are read: another program's stores reach no call here.
fn storedFunctions(self: *Facts, container: Container, name: []const u8) ResolveError!?Value {
    const field = self.member(container, name) orelse return null;
    if (self.project.at(field.file).model.declarations[@backingInt(field.index)].kind != .field) return null;
    if (self.stored.get(field)) |known| return known;
    if (self.storing.contains(field)) {
        self.open_met += 1;
        return null;
    }
    try self.storing.put(self.gpa, field, {});
    defer _ = self.storing.remove(field);
    const wide = self.wide;
    const found = try self.storesOf(container, field);
    if (!self.wideSince(wide)) try self.stored.put(self.gpa, field, found);
    return found;
}

/// What a call through the function-pointer field may reach, from its stores in the files
/// that may share a compilation with its struct (`fieldStores`): one function, or a choice.
fn storesOf(self: *Facts, container: Container, field: Decl) ResolveError!?Value {
    var files: std.ArrayList(Project.FileId) = .empty;
    var each = (try self.compiledWith(container.file)).keyIterator();
    while (each.next()) |key| {
        if (self.project.at(key.*).file.status != .parsed or !try self.importsRead(key.*)) return null;
        try files.append(self.gpa, key.*);
    }
    const targets = (try self.fieldStores(field, files.items)) orelse return null;
    return switch (targets.len) {
        0 => null,
        1 => targets[0],
        else => .{ .alternatives = targets },
    };
}

/// The functions each store in `files` that `accesses` finds may write the field gives it
/// (`stores`). Null where one may give it any: its address taken, a store reading it first, a
/// store with no one value, a computed `@field` that may name it, and memory a cast or an
/// `extern` makes. A whole value copied over it carries what another store gave, and memory a
/// function the program does not hold or `asm` writes holds no function the program declares
/// that a store here did not give: neither adds one.
pub fn fieldStores(self: *Facts, field: Decl, files: []const Project.FileId) ResolveError!?[]const Value {
    var targets: std.ArrayList(Value) = .empty;
    var found_sites = accesses.writesFor(self, .{ .field = field }, files, .{ .holders = false });
    while (try found_sites.next()) |site| {
        const tree = &self.project.at(site.file).file.tree;
        // A store in code no compilation of the program analyzes gives it nothing.
        if (!try self.storeCounts(site.file, site.node)) continue;
        if (site.computed) {
            const target = site.target orelse return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = builtinArgs(tree, target, &buffer);
            if (args.len != 2) return null;
            // `@field` of a type names a declaration of it (`&@field(cpus, name)` with
            // `comptime cpus: type`), no field of a value; a name that ranges over another
            // struct's fields (`for (@typeInfo(T).@"struct".field_names)`) names this field
            // only where that struct has one so named.
            if (try self.isType(site.file, args[0])) continue;
            if (try self.fieldNamesOf(site.file, args[1])) |other| if (!self.hasField(other, self.project.at(field.file).model.declarations[@backingInt(field.index)].name)) continue;
            // In a generic, only a reading whose holder is this field's struct may name it.
            if (try self.holderMisses(site.file, site.node, args[0], field)) continue;
            return null;
        }
        switch (site.kind) {
            .covered => switch (tree.nodeTag(site.node)) {
                // `@bitCast` takes and makes only types of a defined layout: never an auto
                // struct or union, nor one holding one, so never this field of one.
                .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(site.node)), "@bitCast") or !self.autoLayout(field)) if (!try self.castMisses(site.file, site.node, field)) return null,
                else => if (tree.fullVarDecl(site.node) != null) return null,
            },
            .init, .set => switch (site.reach) {
                .exact, .named => if (!try self.stores(&targets, site.file, site.value orelse return null)) return null,
                .holder, .unresolved => {},
            },
            .update => if (site.reach == .exact or site.reach == .named) return null,
            .address => if (site.reach == .exact or site.reach == .named) return null,
            .read => {},
            // A program the unit is read for may store any function.
            .open => return null,
        }
    }
    return targets.items;
}

/// Whether the field's container is laid out by Zig (`struct`, `union`, no `extern` or
/// `packed`).
fn autoLayout(self: *Facts, field: Decl) bool {
    const model = &self.project.at(field.file).model;
    const tree = &self.project.at(field.file).file.tree;
    const scope = model.scopes[@backingInt(model.declarations[@backingInt(field.index)].scope)];
    if (scope.node == .root) return true;
    var buffer: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, scope.node) orelse return false;
    return container.layout_token == null;
}

/// Whether a store at `node` counts for its field (`fieldStores`): its part is analyzed. While
/// the walk builds, a part counts once the walk has reached it. A function a store gives is
/// named at the store, so the walk reaches it when it reaches the store's part, never only
/// through the call: the walk reaches the least set from its roots, and a function stored
/// only in code nothing compiles is never reached. What an unresolved call reaches (a function
/// type, `erased`) is no more than that either.
fn storeCounts(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    const found = self.walk orelse return self.analyzedAt(file, node);
    // An answer narrower than the built analysis may give: no memo keeps what reads it, and
    // `dropMemos` drops what one kept regardless.
    self.wide += 1;
    if (found.everything) return true;
    const part = try self.partOf(file, node) orelse return found.files.contains(file);
    const index = (try self.partsOf(file)).declared.get(part) orelse return switch (self.project.at(file).file.tree.nodeTag(part)) {
        .test_decl => try self.program(file),
        else => found.files.contains(file),
    };
    return found.reached.contains(.{ .file = file, .index = index });
}

/// Whether a pointer cast makes no view of memory that may hold `field`'s struct, in each
/// reading a compilation of the program analyzes its function in (`analyzedReadings`; one,
/// binding nothing, for a function read once): the type its result takes where it is written
/// and its operand's each hold no value of it (`create(T)` with `T` a `u32`; a `[*]u16` field
/// given a `*anyopaque`'s bytes). False where a reading is not known, or a type does not resolve.
fn castMisses(self: *Facts, file: Project.FileId, node: Ast.Node.Index, field: Decl) ResolveError!bool {
    const part = try self.partOf(file, node) orelse return false;
    const index = (try self.partsOf(file)).declared.get(part) orelse return false;
    const function: Decl = .{ .file = file, .index = index };
    if (!self.instantiated(function)) return self.castMissesIn(null, file, node, field);
    for ((try self.analyzedReadings(function)) orelse return false) |reading| {
        if (!try self.castMissesIn(reading, file, node, field)) return false;
    }
    return true;
}

/// `castMisses` in one reading: the cast's result type is the one it makes there (`castTypeIn`).
fn castMissesIn(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index, field: Decl) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, node, &buffer);
    if (args.len != 1) return false;
    const result = try self.castTypeIn(env, file, node);
    const holder = self.project.at(field.file).model.declarations[@backingInt(field.index)].scope;
    if (try self.mayHoldStruct(accesses.held(result), field.file, holder, 0)) return false;
    return !try self.mayHoldStruct(accesses.held(try self.resolveIn(env, file, accesses.uncast(tree, args[0]))), field.file, holder, 0);
}

/// Whether `@field(holder, name)` at `node`, in a function Zig analyzes once per instantiation,
/// names a field of `field`'s struct in none of the readings a compilation of the program
/// analyzes it in: in each, the holder, read with that reading's bindings, is a value of another
/// type or a pointer to one (zon's `&@field(out, info.field_names[j])` for an `out: *T`). A computed
/// name names a field of the holder's own type only. False where a reading is not known or the
/// holder does not resolve.
fn holderMisses(self: *Facts, file: Project.FileId, node: Ast.Node.Index, holder: Ast.Node.Index, field: Decl) ResolveError!bool {
    const part = try self.partOf(file, node) orelse return false;
    const index = (try self.partsOf(file)).declared.get(part) orelse return false;
    const function: Decl = .{ .file = file, .index = index };
    if (!self.genericFunction(function)) return false;
    const readings = (try self.analyzedReadings(function)) orelse return false;
    const scope = self.project.at(field.file).model.declarations[@backingInt(field.index)].scope;
    for (readings) |reading| {
        switch (accesses.held(try self.resolveIn(reading, file, holder))) {
            .container, .instance => |k| if (k.symbolic or (k.file == field.file and k.scope == scope)) return false,
            .primitive, .scalar, .array, .function, .fn_type, .error_set => {},
            else => return false,
        }
    }
    return true;
}

/// Whether a value of `value`'s type may hold, by value, one of the struct `scope` of `file`
/// declares: it is that struct, or one of its fields, elements or payloads may hold one. What
/// a pointer points at is not held; what does not resolve may be.
fn mayHoldStruct(self: *Facts, value: Value, file: Project.FileId, scope: Model.Scope.Id, depth: u8) ResolveError!bool {
    if (depth >= 16) return true;
    switch (value) {
        .container, .instance => |k| {
            if (k.file == file and k.scope == scope) return true;
            if (k.symbolic) return true;
            const model = &self.project.at(k.file).model;
            const tree = &self.project.at(k.file).file.tree;
            for (model.declarations, 0..) |record, d| {
                if (record.kind != .field or record.scope != k.scope) continue;
                // An enum's tag holds no value.
                const declared = model.containerField(tree, record.node) orelse return true;
                if (declared.ast.type_expr == .none) continue;
                if (try self.mayHoldStruct(try self.memberOf(k, .{ .file = k.file, .index = @fromBackingInt(@intCast(d)) }), file, scope, depth + 1)) return true;
            }
            return false;
        },
        .array, .optional, .error_union => |inner| return self.mayHoldStruct(inner.*, file, scope, depth + 1),
        .alternatives => |each| {
            for (each) |one| if (try self.mayHoldStruct(one, file, scope, depth + 1)) return true;
            return false;
        },
        .pointer, .primitive, .scalar, .function, .fn_type, .error_set => return false,
        // A literal with no type of its own holds what its parts do.
        .literal => |key| {
            for (try self.literalParts(key)) |part| if (try self.mayHoldStruct(part, file, scope, depth + 1)) return true;
            return false;
        },
        // A type Zig builds from its fields' types, or a value of one, holds what they do.
        .reified => |built| return self.mayHoldStruct(built.fields.*, file, scope, depth + 1),
        .unknown, .reflected => return true,
    }
}

/// What a compilation of the program analyzes, as Zig analyzes lazily: each function and
/// container-level constant reached from the program's roots, with the readings it is reached
/// in (`every`: one binding nothing, so each instantiation's).
pub const Analysis = struct {
    reached: std.AutoHashMapUnmanaged(Decl, Readings) = .empty,
    /// The files Zig analyzes: the program's, std's root, and each one the walk reaches, by a
    /// part of it read or an `@import` naming it read (`enterFile`). Only such a file's
    /// container-level `comptime` blocks, loose parts and exported declarations are analyzed.
    files: std.AutoHashMapUnmanaged(Project.FileId, void) = .empty,
    /// The member names the walk met on a holder that does not resolve (`reachNamed`): Zig's
    /// member lookup on an unknown holder. A function or container-level constant so named, in
    /// a file Zig analyzes, may be analyzed (`lazilyAnalyzed`); the walk reads none of them.
    named: std.StringHashMapUnmanaged(void) = .empty,
    /// What code the walk did not read may analyze, found when a reader asks (`lazilyAnalyzed`,
    /// `lazilyEntered`), and the sites that may name a declaration or a file (`Sites`).
    lazy: Lazy = .{},
    /// A reach that only records what a site names (`reachedFromSite`): no part is queued.
    checking: bool = false,
    /// Per function, the members of containers it declares reached with no instance known:
    /// each is read in every reading of the function, those found later too.
    members: std.AutoHashMapUnmanaged(Decl, std.ArrayList(Decl)) = .empty,
    /// Anything may be analyzed: at each of `limits`.
    everything: bool = false,
    /// Where the walk could not decide what is analyzed: a file the front end refused (it may
    /// name anything), a reading past its budget, an `@field` whose holder may be a type and
    /// whose name no rule reads (it may analyze any declaration). Each is a coverage limit,
    /// never cleared.
    limits: std.ArrayList(Limit) = .empty,

    built: bool = false,

    pub const Limit = struct { file: Project.FileId, node: Ast.Node.Index, why: enum { refused, budget, reflected } };
    pub const Lazy = struct {
        decls: std.AutoHashMapUnmanaged(Decl, Answer) = .empty,
        files: std.AutoHashMapUnmanaged(Project.FileId, Answer) = .empty,
        /// What answered no while a query it depends on was still open: kept as no once the
        /// outermost query answers no (`lazilyAnalyzed`), dropped where it answers yes.
        provisional: std.ArrayList(LazyKey) = .empty,
        /// What the outermost question in progress answered (`lazyQuery`).
        answered: std.ArrayList(LazyKey) = .empty,
        met_open: bool = false,
        depth: usize = 0,
        steps: usize = 0,
        /// The steps one question may take (`lazy_steps`; a test asks with fewer).
        limit: usize = lazy_steps,
        sites: ?Sites = null,
        pub const Answer = enum { open, yes, no };
    };
    /// Each site that may name a declaration or a file, found once over every file: by the name
    /// it spells (an identifier, a member access, a decl literal), each `@field` (whose name may
    /// be any), and each `@import` by the file it names, or among those naming none the program
    /// holds.
    pub const Sites = struct {
        by_name: std.StringHashMapUnmanaged(std.ArrayList(Key)) = .empty,
        reflected: std.ArrayList(Key) = .empty,
        imports: std.AutoHashMapUnmanaged(Project.FileId, std.ArrayList(Key)) = .empty,
        unresolved_imports: std.ArrayList(Key) = .empty,
    };
    pub const Readings = struct { every: bool = false, envs: std.ArrayList(*const Env) = .empty };
};

/// Per file, the nodes of each part Zig analyzes as one (`partOf`; the file's own loose parts
/// under `.root`), and the part each function and container-level constant is.
pub const FileParts = struct {
    nodes: std.AutoHashMapUnmanaged(Ast.Node.Index, std.ArrayList(Ast.Node.Index)) = .empty,
    declared: std.AutoHashMapUnmanaged(Ast.Node.Index, Model.Declaration.Id) = .empty,
    /// Each node's part, by its index: `.root` where it is in none (`partOf` null).
    of: []const Ast.Node.Index = &.{},
};

/// A part to read and the reading it is read in.
const PartRead = struct { file: Project.FileId, part: Ast.Node.Index, env: ?*const Env };

/// The readings of one declaration kept apart: past them, it is read binding nothing.
const reading_limit = 64;

/// What one reading of a part may spend resolving.
const reading_budget = 100_000;

/// What a compilation of the program analyzes, found once. The roots are every function and
/// container-level constant of the program's files and the program's tests; of each file Zig
/// analyzes (`Analysis.files`: the program's, std's root, one the walk reaches), each exported
/// declaration, its container-level `comptime` blocks and its loose parts. From each part
/// read, in the reading it is reached in: a call reaches its callee in the reading it makes
/// (`calls.under`, `readingAt`); a name, a member, a decl literal or an `@field` naming a
/// function or a container-level constant reaches it (no binding); a member of a holder that
/// does not resolve is named (`Analysis.named`), what it may be found when a reader asks
/// (`lazilyAnalyzed`); an `@field` of a value names a field, of a type
/// whose name is not known each of its declarations, and with neither known anything.
pub fn analysis(self: *Facts) ResolveError!*const Analysis {
    const found = try self.memo(Analysis);
    if (found.built) return found;
    found.built = true;
    // A unit read for every program that may import it: any of its declarations may be
    // analyzed, in any reading.
    if (self.open_world) {
        found.everything = true;
        return found;
    }
    // What the walk asks of the analysis while it is built is answered as if anything may be
    // analyzed (`building_analysis`); what is read on that answer is not kept (`wide`). Once
    // built, what a query in progress reads of it is exact.
    const wide = self.wide;
    defer self.wide = wide;
    self.building_analysis = true;
    defer self.building_analysis = false;
    self.walk = found;
    defer self.walk = null;
    // The walk is a unit of solving on a budget of its own, as each reading in it is
    // (`reachAll`): it is never charged to whoever asks first.
    const asker = self.enter(reading_budget);
    const walked = self.reachAll(found);
    if (self.leave(asker)) found.everything = true;
    try walked;
    self.dropMemos();
    return found;
}

/// Replaces each memo the walk was handed (`walked`), which it may have filled with an answer
/// read before a store's part was reached (`storeCounts`), whatever kind of answer the memo
/// keeps: the next query makes it again, of the built analysis. The analysis itself is kept, and
/// every memo no part of the walk asked for keeps what it holds. A replaced memo is left in the
/// arena, never cleared: a query up the stack holding it writes into storage nothing reads again.
fn dropMemos(self: *Facts) void {
    const kept = comptime std.hash.Wyhash.hash(0, @typeName(Analysis));
    var each = self.walked.keyIterator();
    while (each.next()) |key| if (key.* != kept) {
        _ = self.memos.remove(key.*);
        _ = self.lasting.remove(key.*);
    };
    self.walked = .empty;
}

/// Builds `found` (`analysis`).
fn reachAll(self: *Facts, found: *Analysis) ResolveError!void {
    var next: std.ArrayList(PartRead) = .empty;
    for (self.project.sources) |*source| {
        if (source.file.status != .parsed) {
            try found.limits.append(self.gpa, .{ .file = source.id, .node = .root, .why = .refused });
            found.everything = true;
            continue;
        }
        if (try self.program(source.id)) try self.enterFile(found, &next, source.id);
    }
    // Every compilation analyzes std's root, which reaches `start` (`comptime { _ = start; }`).
    for (self.project.imports) |mapping| if (std.mem.eql(u8, mapping.spelling, "std")) try self.enterFile(found, &next, mapping.target);
    // Each reading is a unit on a budget of its own; what it reads is memoized for the others.
    var cache: std.AutoHashMapUnmanaged(Ast.Node.Index, bool) = .empty;
    defer cache.deinit(self.gpa);
    while (next.pop()) |reading| {
        // A part of a file read: the file's container is analyzed, so its own roots are.
        try self.enterFile(found, &next, reading.file);
        // A reading queued before its declaration came to be read binding nothing (`every`)
        // is one that reading covers, as `readDeclaration` makes no new one past it.
        if (reading.env != null) if ((try self.partsOf(reading.file)).declared.get(reading.part)) |d| {
            if (found.reached.get(.{ .file = reading.file, .index = d })) |readings| if (readings.every) continue;
        };
        cache.clearRetainingCapacity();
        const asker = self.enter(reading_budget);
        const read = self.readPart(found, &next, &cache, reading);
        const short = self.leave(asker);
        try read;
        if (!short) continue;
        try found.limits.append(self.gpa, .{ .file = reading.file, .node = reading.part, .why = .budget });
        found.everything = true;
    }
}

/// Reads one part in its reading (`reachAll`), `cache` the reading's reachability (`reachedCached`).
fn readPart(self: *Facts, found: *Analysis, next: *std.ArrayList(PartRead), cache: *std.AutoHashMapUnmanaged(Ast.Node.Index, bool), reading: PartRead) ResolveError!void {
    const nodes = (try self.partsOf(reading.file)).nodes.get(reading.part) orelse return;
    for (nodes.items) |node| {
        // A branch the reading's bindings rule out is not analyzed in it (`.array`
        // of a `switch (@typeInfo(T))` reading a pointer `T`).
        if (!try self.reachedCached(cache, reading.env, reading.file, node)) continue;
        try self.reachFrom(found, next, reading.file, node, reading.env);
    }
}

/// Queues the roots of a file Zig analyzes, once (`Analysis.files`): of the program's, every
/// function and container-level constant and each test; of any, each exported declaration,
/// its container-level `comptime` blocks and its loose parts. A file no compilation imports is
/// never analyzed, nor anything in it.
fn enterFile(self: *Facts, found: *Analysis, next: *std.ArrayList(PartRead), file: Project.FileId) ResolveError!void {
    const source = self.project.at(file);
    if (source.file.status != .parsed or source.file.tree.mode != .zig) return;
    const entry = try found.files.getOrPut(self.gpa, file);
    if (entry.found_existing or found.checking) return;
    const own = try self.program(file);
    const model = &source.model;
    for (model.declarations, 0..) |record, d| {
        if (!own and !record.exported) continue;
        const decl: Decl = .{ .file = file, .index = @fromBackingInt(@intCast(d)) };
        // An instantiated one is read in the instantiations the walk reaches it in; one a
        // consumer may instantiate (the program's public one), in each.
        if (!self.instantiated(decl) or (own and record.public)) try self.reachDeclaration(found, next, decl, null);
    }
    const tree = &source.file.tree;
    var parts = (try self.partsOf(file)).nodes.keyIterator();
    while (parts.next()) |part| {
        const loose = part.* == .root;
        if (loose or tree.nodeTag(part.*) == .@"comptime" or (own and tree.nodeTag(part.*) == .test_decl)) try next.append(self.gpa, .{ .file = file, .part = part.*, .env = null });
    }
}

/// Whether a file's container-level `comptime` blocks and loose parts are analyzed: the walk
/// entered it (`enterFile`), or anything may be analyzed.
fn fileAnalyzed(self: *Facts, file: Project.FileId) ResolveError!bool {
    if (self.building_analysis) {
        self.wide += 1;
        return true;
    }
    const found = try self.builtAnalysis();
    return found.everything or found.files.contains(file) or try self.lazilyEntered(found, file);
}

/// Whether an answer wider than the analysis gives once built was given since `mark` (`wide`, read
/// before): a memo keeps nothing read since then.
pub fn wideSince(self: *const Facts, mark: usize) bool {
    return self.wide != mark;
}

/// Whether a compilation of the program may analyze `decl` (`analysis`).
pub fn analyzed(self: *Facts, decl: Decl) ResolveError!bool {
    if (self.building_analysis) {
        self.wide += 1;
        return true;
    }
    const found = try self.builtAnalysis();
    return found.everything or found.reached.contains(decl) or try self.lazilyAnalyzed(found, decl);
}

/// Whether the part of a file holding `node` is analyzed: its function's or constant's
/// declaration is; a `comptime` block or a loose part of a file the walk entered is
/// (`fileAnalyzed`); a test is in the program's files.
pub fn analyzedAt(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    const part = try self.partOf(file, node) orelse return self.fileAnalyzed(file);
    const d = (try self.partsOf(file)).declared.get(part) orelse return switch (self.project.at(file).file.tree.nodeTag(part)) {
        .test_decl => try self.program(file),
        else => try self.fileAnalyzed(file),
    };
    return self.analyzed(.{ .file = file, .index = d });
}

/// The readings a declaration is analyzed in, or null where it is read in each one (binding
/// nothing) or anything may be analyzed.
pub fn analyzedReadings(self: *Facts, decl: Decl) ResolveError!?[]const *const Env {
    if (self.building_analysis) {
        self.wide += 1;
        return null;
    }
    const found = try self.builtAnalysis();
    if (found.everything) return null;
    // Code the walk did not read reads it binding nothing, as each instantiation's; a member of
    // a container a function declares, in each reading of that function.
    if (try self.lazilyAnalyzed(found, decl)) return self.lazyReadings(found, decl);
    const readings = found.reached.get(decl) orelse return &.{};
    return if (readings.every) null else readings.envs.items;
}

/// The analysis once built (`analysis`), which keeps the answers its readers' questions of code
/// the walk did not read find (`Analysis.lazy`).
fn builtAnalysis(self: *Facts) ResolveError!*Analysis {
    _ = try self.analysis();
    return self.memo(Analysis);
}

/// Most steps one reader's question of code the walk did not read takes (`lazilyAnalyzed`):
/// past them, the answer is that it may be analyzed.
const lazy_steps = 200_000;

/// Whether code the walk did not read may analyze `decl` (`analysis` reaches only by
/// declaration): Zig's lazy analysis asked backwards, its least fixpoint. A function or
/// container-level constant is, in a file Zig analyzes (`lazilyEntered`), where the walk met a
/// member of an unknown holder spelled as its name (`Analysis.named`), where it is exported from
/// a file the walk did not enter, or where a site that may name it (`Sites`) lies in code the
/// walk did not read that is analyzed, read binding nothing (`reachedFromSite`). A cycle no root
/// reaches is analyzed nowhere, as in Zig. Past `lazy_steps`, it may be.
fn lazilyAnalyzed(self: *Facts, found: *Analysis, decl: Decl) ResolveError!bool {
    const lazy = &found.lazy;
    if (lazy.decls.get(decl)) |known| switch (known) {
        .yes => return true,
        .no => return false,
        .open => {
            lazy.met_open = true;
            return false;
        },
    };
    return self.lazyQuery(found, .{ .decl = decl });
}

/// Whether code the walk did not read imports `file` (`lazilyAnalyzed`): an `@import` naming it
/// in such code that is analyzed, or one naming no file the program holds in analyzed code.
fn lazilyEntered(self: *Facts, found: *Analysis, file: Project.FileId) ResolveError!bool {
    const lazy = &found.lazy;
    if (lazy.files.get(file)) |known| switch (known) {
        .yes => return true,
        .no => return false,
        .open => {
            lazy.met_open = true;
            return false;
        },
    };
    return self.lazyQuery(found, .{ .file = file });
}

const LazyKey = union(enum) { decl: Decl, file: Project.FileId };

/// One question of `lazilyAnalyzed` or `lazilyEntered`. The outermost is a unit of its own, as
/// each reading of the walk is (`enter`): the reader asking is charged nothing for it, and where
/// it runs short of its budget, what it answered no is dropped and its answer is that it may be.
fn lazyQuery(self: *Facts, found: *Analysis, key: LazyKey) ResolveError!bool {
    const lazy = &found.lazy;
    if (lazy.depth != 0) return self.lazyAsk(found, key, false);
    lazy.steps = 0;
    lazy.answered.clearRetainingCapacity();
    const asker = self.enter(reading_budget);
    const inner = self.lazyAsk(found, key, true);
    const short = self.leave(asker);
    const yes = try inner;
    if (!short) return yes;
    for (lazy.answered.items) |each| switch (each) {
        .decl => |d| if (lazy.decls.get(d) == .no) {
            _ = lazy.decls.remove(d);
        },
        .file => |f| if (lazy.files.get(f) == .no) {
            _ = lazy.files.remove(f);
        },
    };
    switch (key) {
        .decl => |d| try lazy.decls.put(self.gpa, d, .yes),
        .file => |f| try lazy.files.put(self.gpa, f, .yes),
    }
    return true;
}

/// `lazyQuery`'s question, kept: yes always, no once nothing it read was open, or once the
/// outermost question answers no (what it read then reaches no root).
fn lazyAsk(self: *Facts, found: *Analysis, key: LazyKey, outermost: bool) ResolveError!bool {
    const lazy = &found.lazy;
    switch (key) {
        .decl => |d| try lazy.decls.put(self.gpa, d, .open),
        .file => |f| try lazy.files.put(self.gpa, f, .open),
    }
    const met_before = lazy.met_open;
    lazy.met_open = false;
    lazy.depth += 1;
    const answer = switch (key) {
        .decl => |d| self.lazyDecl(found, d),
        .file => |f| self.lazyFile(found, f),
    };
    lazy.depth -= 1;
    const yes = answer catch |err| {
        switch (key) {
            .decl => |d| _ = lazy.decls.remove(d),
            .file => |f| _ = lazy.files.remove(f),
        }
        return err;
    };
    const met = lazy.met_open;
    lazy.met_open = met_before or met;
    const kept: Analysis.Lazy.Answer = if (yes) .yes else .no;
    switch (key) {
        .decl => |d| try lazy.decls.put(self.gpa, d, kept),
        .file => |f| try lazy.files.put(self.gpa, f, kept),
    }
    try lazy.answered.append(self.gpa, key);
    if (!yes and met and !outermost) try lazy.provisional.append(self.gpa, key);
    if (outermost) {
        // A no read while a question was open stands only where the outermost one is no.
        if (yes) for (lazy.provisional.items) |held| switch (held) {
            .decl => |d| _ = lazy.decls.remove(d),
            .file => |f| _ = lazy.files.remove(f),
        };
        lazy.provisional.clearRetainingCapacity();
        lazy.met_open = false;
    }
    return yes;
}

/// `lazilyAnalyzed`'s reading of one declaration.
fn lazyDecl(self: *Facts, found: *Analysis, decl: Decl) ResolveError!bool {
    const model = &self.project.at(decl.file).model;
    const record = model.declarations[@backingInt(decl.index)];
    if (record.kind != .function and record.kind != .variable) return false;
    const part = try self.partOf(decl.file, record.node) orelse return false;
    if ((try self.partsOf(decl.file)).declared.get(part) != decl.index) return false;
    if (!found.files.contains(decl.file) and !try self.lazilyEntered(found, decl.file)) return false;
    // A member of a container a function declares exists only in that function's instances
    // (`reachDeclaration`): analyzed where the function is, in its readings.
    if (self.instantiated(decl)) if (self.enclosingFunction(decl)) |outer| {
        if (!found.reached.contains(outer) and !try self.lazilyAnalyzed(found, outer)) return false;
    };
    if (found.named.contains(record.name)) return true;
    if (record.exported and !found.files.contains(decl.file)) return true;
    const sites = try self.lazySites(found);
    for ([_][]const Key{ if (sites.by_name.get(record.name)) |list| list.items else &.{}, sites.reflected.items }) |each| for (each) |site| {
        if (try self.lazyStep(found)) return true;
        if (!try self.lazilyRead(found, site)) continue;
        if (try self.reachedFromSite(found, site, decl)) return true;
    };
    return false;
}

/// `lazilyEntered`'s reading of one file.
fn lazyFile(self: *Facts, found: *Analysis, file: Project.FileId) ResolveError!bool {
    if (self.project.at(file).file.status != .parsed) return false;
    const sites = try self.lazySites(found);
    for ((sites.imports.get(file) orelse return self.importsUnresolved(found, sites)).items) |site| {
        if (try self.lazyStep(found)) return true;
        // An import the walk read entered its file already: one it did not, read lazily.
        if (try self.lazilyRead(found, site)) return true;
    }
    return self.importsUnresolved(found, sites);
}

/// Whether analyzed code holds an `@import` naming no file the program holds, which may be any
/// (`lazilyEntered`): code the walk read, or code it did not that is analyzed.
fn importsUnresolved(self: *Facts, found: *Analysis, sites: *const Analysis.Sites) ResolveError!bool {
    for (sites.unresolved_imports.items) |site| {
        if (try self.lazyStep(found)) return true;
        const part = try self.partOf(site.file, site.node) orelse {
            if (found.files.contains(site.file) or try self.lazilyEntered(found, site.file)) return true;
            continue;
        };
        if ((try self.partsOf(site.file)).declared.get(part)) |d| {
            if (found.reached.contains(.{ .file = site.file, .index = d })) return true;
        } else if (found.files.contains(site.file)) return true;
        if (try self.lazilyRead(found, site)) return true;
    }
    return false;
}

/// Counts a step of a reader's question (`lazy_steps`): true past them, it may be analyzed.
fn lazyStep(self: *Facts, found: *Analysis) ResolveError!bool {
    _ = self;
    found.lazy.steps += 1;
    return found.lazy.steps > found.lazy.limit;
}

/// Whether `site` lies in code the walk did not read that is analyzed: a part whose declaration
/// the walk read in no reading binding nothing, analyzed lazily (`lazilyAnalyzed`); a file's
/// loose part or `comptime` block where the walk did not enter the file but code it did not read
/// imports it. A test is the program's, read by the walk.
fn lazilyRead(self: *Facts, found: *Analysis, site: Key) ResolveError!bool {
    const part = try self.partOf(site.file, site.node) orelse return !found.files.contains(site.file) and try self.lazilyEntered(found, site.file);
    const d = (try self.partsOf(site.file)).declared.get(part) orelse return switch (self.project.at(site.file).file.tree.nodeTag(part)) {
        .test_decl => false,
        else => !found.files.contains(site.file) and try self.lazilyEntered(found, site.file),
    };
    const decl: Decl = .{ .file = site.file, .index = d };
    if (found.reached.get(decl)) |readings| if (readings.every) return false;
    return self.lazilyAnalyzed(found, decl);
}

/// The readings code the walk did not read analyzes `decl` in, where it may (`lazilyAnalyzed`):
/// a member of a container a function declares, each reading of that function, where the walk
/// read the function in each it has (code it did not read analyzes the function nowhere, so
/// makes no other instance); otherwise null, each one's (binding nothing).
fn lazyReadings(self: *Facts, found: *Analysis, decl: Decl) ResolveError!?[]const *const Env {
    if (!self.instantiated(decl)) return null;
    const outer = self.enclosingFunction(decl) orelse return null;
    const readings = found.reached.get(outer) orelse return null;
    if (readings.every or try self.lazilyAnalyzed(found, outer)) return null;
    return readings.envs.items;
}

/// Whether what `site` names, read in the readings code the walk did not read analyzes its part
/// in (`lazyReadings`), may be `decl`: a reach of it by declaration, or a member of an unknown
/// holder spelled as its name, as the walk reads the site (`reachFrom`) and the call the site
/// is the callee of, recording what it reaches only.
fn reachedFromSite(self: *Facts, found: *Analysis, site: Key, decl: Decl) ResolveError!bool {
    const envs: ?[]const *const Env = if (try self.partOf(site.file, site.node)) |part| if ((try self.partsOf(site.file)).declared.get(part)) |d| try self.lazyReadings(found, .{ .file = site.file, .index = d }) else null else null;
    var check: Analysis = .{ .checking = true };
    var next: std.ArrayList(PartRead) = .empty;
    // A unit of its own (`enter`): the reader asking is charged nothing for it.
    const asker = self.enter(reading_budget);
    const read = if (envs) |each| self.readSiteIn(&check, &next, site, each) else self.readSite(&check, &next, site, null);
    if (self.leave(asker)) return true;
    if (!try read) return false;
    if (check.everything or check.reached.contains(decl)) return true;
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    return check.named.contains(record.name);
}

/// `readSite` in each of `envs`: false where none reaches the site.
fn readSiteIn(self: *Facts, check: *Analysis, next: *std.ArrayList(PartRead), site: Key, envs: []const *const Env) ResolveError!bool {
    var any = false;
    for (envs) |env| {
        if (try self.readSite(check, next, site, env)) any = true;
    }
    return any;
}

/// Reads one site and the call it is the callee of in `env` (`reachedFromSite`).
/// False where the reading does not reach the site (`reachedUnder`).
fn readSite(self: *Facts, check: *Analysis, next: *std.ArrayList(PartRead), site: Key, env: ?*const Env) ResolveError!bool {
    if (!try self.reachedUnder(env, site.file, site.node)) return false;
    try self.reachFrom(check, next, site.file, site.node, env);
    const model = &self.project.at(site.file).model;
    var at = site.node;
    var parent = model.parentOf(at) orelse return true;
    if (self.project.at(site.file).file.tree.nodeTag(parent) == .deref) {
        at = parent;
        parent = model.parentOf(at) orelse return true;
    }
    var buffer: [1]Ast.Node.Index = undefined;
    const call = self.project.at(site.file).file.tree.fullCall(&buffer, parent) orelse return true;
    if (call.ast.fn_expr == at) try self.reachFrom(check, next, site.file, parent, env);
    return true;
}

/// The sites of every file (`Analysis.Sites`), found once.
fn lazySites(self: *Facts, found: *Analysis) ResolveError!*const Analysis.Sites {
    if (found.lazy.sites) |*known| return known;
    var sites: Analysis.Sites = .{};
    for (self.project.sources) |*source| {
        if (source.file.status != .parsed or source.file.tree.mode != .zig) continue;
        const tree = &source.file.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const spelled: Ast.TokenIndex = switch (tag) {
                .identifier, .enum_literal => tree.nodeMainToken(node),
                .field_access => tree.nodeData(node).node_and_token[1],
                .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                    const builtin_name = tree.tokenSlice(tree.nodeMainToken(node));
                    if (std.mem.eql(u8, builtin_name, "@field")) try sites.reflected.append(self.gpa, .{ .file = source.id, .node = node });
                    if (std.mem.eql(u8, builtin_name, "@import")) try self.importSite(&sites, source.id, node);
                    continue;
                },
                else => continue,
            };
            const entry = try sites.by_name.getOrPut(self.gpa, try self.memberName(tree.tokenSlice(spelled)));
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(self.gpa, .{ .file = source.id, .node = node });
        }
    }
    found.lazy.sites = sites;
    return &found.lazy.sites.?;
}

/// Files an `@import` site names (`lazySites`): each the project maps it to, or none it holds
/// (one Zig's own build makes, `builtin` or `root`, names none of the program's).
fn importSite(self: *Facts, sites: *Analysis.Sites, file: Project.FileId, node: Ast.Node.Index) ResolveError!void {
    const tree = &self.project.at(file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, node, &buffer);
    const site: Key = .{ .file = file, .node = node };
    if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) return sites.unresolved_imports.append(self.gpa, site);
    const spelling = std.zig.string_literal.parseAlloc(self.gpa, tree.tokenSlice(tree.nodeMainToken(args[0]))) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLiteral => return sites.unresolved_imports.append(self.gpa, site),
    };
    var reached: [2]Project.FileId = undefined;
    const targets = self.project.importedAll(file, spelling, &reached);
    if (targets.len == 0) {
        if (self.project.absent(file, spelling) or try self.zigOwn(file, spelling)) return;
        return sites.unresolved_imports.append(self.gpa, site);
    }
    for (targets) |target| {
        const entry = try sites.imports.getOrPut(self.gpa, target);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(self.gpa, site);
    }
}

/// Reaches a function or a container-level constant in `env`, queueing its part to be read in
/// it unless it already was (`sameReading`).
fn reachDeclaration(self: *Facts, found: *Analysis, next: *std.ArrayList(PartRead), decl: Decl, env: ?*const Env) ResolveError!void {
    const model = &self.project.at(decl.file).model;
    const record = model.declarations[@backingInt(decl.index)];
    if (record.kind != .function and record.kind != .variable) return;
    const part = try self.partOf(decl.file, record.node) orelse return;
    // Only a part's own declaration: a local reaches nothing beyond its function.
    if ((try self.partsOf(decl.file)).declared.get(part) != decl.index) return;
    if (found.checking) {
        _ = try found.reached.getOrPut(self.gpa, decl);
        return;
    }
    // A member of a container a function declares, reached with no instance known, generic
    // itself or not: read in each reading of that function, the ones it is reached in later
    // too, its own comptime parameters unbound there; none while nothing reaches the function,
    // since no instance exists until it is evaluated, and every evaluation names it (a call, or
    // the function handed as a value, each of which reaches it).
    if (env == null and self.instantiated(decl)) if (self.enclosingFunction(decl)) |outer| {
        const pending = try found.members.getOrPut(self.gpa, outer);
        if (!pending.found_existing) pending.value_ptr.* = .empty;
        for (pending.value_ptr.items) |known| {
            if (std.meta.eql(known, decl)) break;
        } else try pending.value_ptr.append(self.gpa, decl);
        const outer_readings = found.reached.get(outer) orelse return;
        if (!outer_readings.every) {
            for (outer_readings.envs.items) |each| try self.readDeclaration(found, next, decl, part, each);
            return;
        }
    };
    try self.readDeclaration(found, next, decl, part, env);
}

/// Queues `decl`'s part to be read in `env` unless it already was, and each member reached
/// with no instance known of a container it declares in the same reading.
fn readDeclaration(self: *Facts, found: *Analysis, next: *std.ArrayList(PartRead), decl: Decl, part: Ast.Node.Index, env: ?*const Env) ResolveError!void {
    const entry = try found.reached.getOrPut(self.gpa, decl);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    const readings = entry.value_ptr;
    if (readings.every) return;
    var reading = env;
    if (env) |bound| {
        // Readings are made once by content (`keptReading`): one is the same reading as another
        // only where it is that one.
        for (readings.envs.items) |known| if (known == bound) return;
        if (readings.envs.items.len < reading_limit) try readings.envs.append(self.gpa, bound) else reading = null;
    }
    if (reading == null) readings.every = true;
    try next.append(self.gpa, .{ .file = decl.file, .part = part, .env = reading });
    const members = (found.members.get(decl) orelse return).items;
    for (members) |held| {
        const member_record = self.project.at(held.file).model.declarations[@backingInt(held.index)];
        const member_part = try self.partOf(held.file, member_record.node) orelse continue;
        try self.readDeclaration(found, next, held, member_part, reading);
    }
}

/// The function whose body declares the container `decl` is a member of: a type function, or
/// any function declaring a container.
fn enclosingFunction(self: *Facts, decl: Decl) ?Decl {
    const model = &self.project.at(decl.file).model;
    var at: ?Model.Scope.Id = model.declarations[@backingInt(decl.index)].scope;
    while (at) |s| : (at = model.scopes[@backingInt(s)].parent) {
        const scope = model.scopes[@backingInt(s)];
        if (scope.kind != .function) continue;
        const d = (self.partsOf(decl.file) catch return null).declared.get(scope.node) orelse return null;
        return .{ .file = decl.file, .index = d };
    }
    return null;
}

/// What one node of a part read in `env` reaches.
fn reachFrom(self: *Facts, found: *Analysis, next: *std.ArrayList(PartRead), file: Project.FileId, node: Ast.Node.Index, env: ?*const Env) ResolveError!void {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    if (try calls.under(self, env, file, node)) |call| switch (call.callee) {
        .function => |decl| try self.reachCalled(found, next, file, node, decl, env),
        .choice => |decls| for (decls) |decl| try self.reachCalled(found, next, file, node, decl, env),
        .any => {},
    };
    switch (tree.nodeTag(node)) {
        .identifier => {
            if (try self.calledKnown(env, file, node)) return;
            const reference = model.reference(node) orelse return;
            if (reference.declaration) |d| return self.reachDeclaration(found, next, .{ .file = file, .index = d }, try self.instanceOf(.{ .file = file, .index = d }, null, env));
            switch (reference.unknown orelse return) {
                .primitive, .literal_context => {},
                .unresolved, .invalid_lowering, .before_declaration => try self.reachNamed(found, next, try self.memberName(tree.tokenSlice(tree.nodeMainToken(node)))),
            }
        },
        .field_access => {
            if (try self.calledKnown(env, file, node)) return;
            const holder, const member_token = tree.nodeData(node).node_and_token;
            // Not called, a member read off a value is a field (Zig: "no field named").
            const is_callee = if (model.parentOf(node)) |parent| blk: {
                var buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buffer, parent) orelse break :blk false;
                break :blk call.ast.fn_expr == node;
            } else false;
            if (!is_callee and try self.valueIn(env, file, holder, 0)) return;
            try self.reachMember(found, next, try self.resolveIn(env, file, holder), try self.memberName(tree.tokenSlice(member_token)), env, is_callee);
        },
        .enum_literal => {
            if (try self.calledKnown(env, file, node)) return;
            const name = try self.memberName(tree.tokenSlice(tree.nodeMainToken(node)));
            switch (try self.literalDeclaration(file, node, name)) {
                .decl => |decl| try self.reachDeclaration(found, next, decl, try self.instanceOf(decl, null, env)),
                .unknown => try self.reachNamed(found, next, name),
                .none => {},
            }
        },
        .builtin_call_two, .builtin_call_two_comma => {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = builtinArgs(tree, node, &buffer);
            // An import read analyzes the file it names, either one where two compilations
            // bind the name apart.
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) {
                if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) return;
                const spelling = std.zig.string_literal.parseAlloc(self.gpa, tree.tokenSlice(tree.nodeMainToken(args[0]))) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidLiteral => return,
                };
                var reached: [2]Project.FileId = undefined;
                for (self.project.importedAll(file, spelling, &reached)) |target| try self.enterFile(found, next, target);
                return;
            }
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field")) return;
            if (args.len != 2) return;
            try self.reachReflected(found, next, file, node, args[0], args[1], env);
        },
        else => {},
    }
}

/// Reaches what a call at `node` calls in `env`: a generic function in the reading the call
/// makes of it (`readingFrom`), a member of a container a type function made in that
/// container's instantiation (`instanceOf`), anything else once.
fn reachCalled(self: *Facts, found: *Analysis, next: *std.ArrayList(PartRead), file: Project.FileId, node: Ast.Node.Index, decl: Decl, env: ?*const Env) ResolveError!void {
    if (self.genericFunction(decl)) return self.reachEach(found, next, decl, try self.readingFrom(file, node, decl, env), 0);
    var holder: ?Container = null;
    var buffer: [1]Ast.Node.Index = undefined;
    const tree = &self.project.at(file).file.tree;
    if (tree.fullCall(&buffer, node)) |call| if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        holder = madeHolder(try self.resolveIn(env, file, tree.nodeData(call.ast.fn_expr).node_and_token[0]));
    };
    try self.reachDeclaration(found, next, decl, try self.instanceOf(decl, holder, env));
}

/// Reaches the generic `decl` in `reading`, one reading per type an argument may be where it
/// is one of several (`inline for` over a union's fields handing each field's type): Zig
/// instantiates the generic once per argument a `comptime`, `type` or `anytype` parameter
/// takes, never with a choice. From the argument at `from` on.
fn reachEach(self: *Facts, found: *Analysis, next: *std.ArrayList(PartRead), decl: Decl, reading: ?*const Env, from: usize) ResolveError!void {
    const bound = reading orelse return self.reachDeclaration(found, next, decl, null);
    const tree = &self.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, self.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return self.reachDeclaration(found, next, decl, bound);
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (position >= bound.args.len) break;
        if (position < from or bound.args[position] != .alternatives) continue;
        const instantiates = param.anytype_ellipsis3 != null or
            (if (param.comptime_noalias) |token| tree.tokenTag(token) == .keyword_comptime else false) or
            (if (param.type_expr) |t| namesType(tree, t) else false);
        if (!instantiates) continue;
        for (bound.args[position].alternatives) |one| {
            const args = try self.gpa.dupe(Value, bound.args);
            args[position] = one;
            // Each split is a reading made once by its content (`keptReading`), as every one is.
            var draft = bound.*;
            draft.args = args;
            try self.reachEach(found, next, decl, try self.keptReading(draft), position + 1);
        }
        return;
    }
    try self.reachDeclaration(found, next, decl, bound);
}

/// The container a value is or is an instance of, through a pointer.
fn madeHolder(value: Value) ?Container {
    return switch (value) {
        .container, .instance => |k| k,
        .pointer => |inner| madeHolder(inner.child.*),
        else => null,
    };
}

/// Whether `decl` is a function with a `comptime`, `type` or `anytype` parameter: Zig
/// analyzes it once per instantiation, each a call's.
fn genericFunction(self: *const Facts, decl: Decl) bool {
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .function) return false;
    const tree = &self.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, record.node) orelse return false;
    return isGeneric(tree, proto);
}

/// Whether Zig analyzes `decl` once per instantiation: a generic function, or a member of a
/// container a function declares (a type function's), which its parameters fix.
fn instantiated(self: *const Facts, decl: Decl) bool {
    if (self.genericFunction(decl)) return true;
    const model = &self.project.at(decl.file).model;
    var at: ?Model.Scope.Id = model.declarations[@backingInt(decl.index)].scope;
    while (at) |s| : (at = model.scopes[@backingInt(s)].parent) {
        if (model.scopes[@backingInt(s)].kind == .function) return true;
    }
    return false;
}

/// The instantiation a member of a type function's container is read in: that of the
/// container it is reached through (`holder`, a type function made), else the reading
/// `env` is made in whose function declares it; none (each one's) where neither is known, and
/// for a declaration read once.
fn instanceOf(self: *Facts, decl: Decl, holder: ?Container, env: ?*const Env) ResolveError!?*const Env {
    if (self.genericFunction(decl) or !self.instantiated(decl)) return null;
    if (holder) |k| if (k.made_by) |made| return try self.madeEnv(made);
    const scope = self.project.at(decl.file).model.declarations[@backingInt(decl.index)].scope;
    var at = env;
    while (at) |reading| : (at = reading.outer) {
        if (reading.function.file == decl.file and self.enclosed(decl.file, scope, self.scopeNode(reading.function))) return reading;
    }
    return null;
}

/// Whether `node` is what a call calls and the call's callee is known: the call reached it.
fn calledKnown(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    const parent = self.project.at(file).model.parentOf(node) orelse return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = self.project.at(file).file.tree.fullCall(&buffer, parent) orelse return false;
    if (call.ast.fn_expr != node) return false;
    const read = (try calls.under(self, env, file, parent)) orelse return false;
    return read.callee != .any;
}

/// What a member `name` read through `holder` reaches: the declaration of its container so
/// named; through a holder that does not resolve, every declaration so named.
fn reachMember(self: *Facts, found: *Analysis, next: *std.ArrayList(PartRead), holder: Value, name: []const u8, env: ?*const Env, is_callee: bool) ResolveError!void {
    switch (holder) {
        .container => |k| if (self.member(k, name)) |decl| try self.reachDeclaration(found, next, decl, try self.instanceOf(decl, k, env)),
        // An instance's member is a field, but where called (a method).
        .instance => |k| if (is_callee) if (self.member(k, name)) |decl| try self.reachDeclaration(found, next, decl, try self.instanceOf(decl, k, env)),
        .pointer => |p| try self.reachMember(found, next, p.child.*, name, env, is_callee),
        .optional => |inner| try self.reachMember(found, next, inner.*, name, env, is_callee),
        .alternatives => |each| for (each) |one| try self.reachMember(found, next, one, name, env, is_callee),
        // Zig's own per-build file (`builtin`, `root`) holds values and none of the program's
        // types: a member of it not called is a field. A method called on one may be std's.
        .unknown => |why| if (is_callee or why != .zig_own) try self.reachNamed(found, next, name),
        else => {},
    }
}

/// What `@field(holder, name)` at `node` reaches in `env`. Of a value it names a field, unless
/// it is called (`@field(x, name)(…)`, `@field(x, name).*(…)`): a method of the value's type
/// may be so named. Of a type, the declaration its name names, or where its name is not known
/// each of its declarations, unless the name ranges over that type's fields. Of what does not
/// resolve, every declaration its name names, or with no name known anything.
fn reachReflected(self: *Facts, found: *Analysis, next: *std.ArrayList(PartRead), file: Project.FileId, node: Ast.Node.Index, holder: Ast.Node.Index, name_node: Ast.Node.Index, env: ?*const Env) ResolveError!void {
    const through_call = self.calledThrough(file, node);
    if (!through_call and try self.valueIn(env, file, holder, 0)) return;
    const name = try self.nameIn(env, file, name_node, 0);
    // A name one of a type's field names: no declaration of that type, a value of it or its
    // tag type has one so named (Zig refuses a member named twice); another container's
    // declarations so named, where the type is known.
    const over = try self.namesOf(file, name_node, 0);
    if (over) |names| if (self.namesNoDeclaration(file, holder, names)) return;
    if (try self.fieldGuarded(file, holder, name_node)) return;
    const fields: ?Container = if (over) |names| switch (try self.resolveIn(env, file, names.subject)) {
        .container => |k| k,
        else => null,
    } else try self.tagNamesOf(env, file, name_node);
    const resolved = try self.resolveIn(env, file, holder);
    // A value's type, where what is called through it may be its method.
    const typed: Value = if (through_call) switch (resolved) {
        .instance => |k| .{ .container = k },
        .pointer => |p| if (p.child.* == .instance) .{ .container = p.child.instance } else resolved,
        else => resolved,
    } else resolved;
    switch (typed) {
        .container => |k| {
            if (name) |known| return if (self.member(k, known)) |decl| self.reachDeclaration(found, next, decl, try self.instanceOf(decl, k, env));
            if (fields) |of| {
                if (of.file == k.file and of.scope == k.scope) return;
                for (self.fieldNames(of)) |field| if (self.member(k, field)) |decl| try self.reachDeclaration(found, next, decl, try self.instanceOf(decl, k, env));
                return;
            }
            const model = &self.project.at(k.file).model;
            for (model.declarations, 0..) |record, d| if (record.scope == k.scope) {
                const decl: Decl = .{ .file = k.file, .index = @fromBackingInt(@intCast(d)) };
                try self.reachDeclaration(found, next, decl, try self.instanceOf(decl, k, env));
            };
        },
        // Zig's own per-build values hold none of the program's declarations.
        .unknown => |why| if (why == .zig_own) {} else if (name) |known| try self.reachNamed(found, next, known) else if (fields) |of| {
            for (self.fieldNames(of)) |field| try self.reachNamed(found, next, field);
        } else {
            try found.limits.append(self.gpa, .{ .file = file, .node = holder, .why = .reflected });
            found.everything = true;
        },
        else => {},
    }
}

/// Whether what `node` gives is called: `node(…)`, or `node.*(…)` through a pointer.
fn calledThrough(self: *Facts, file: Project.FileId, node: Ast.Node.Index) bool {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var callee = node;
    var parent = model.parentOf(node) orelse return false;
    if (tree.nodeTag(parent) == .deref) {
        callee = parent;
        parent = model.parentOf(parent) orelse return false;
    }
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, parent) orelse return false;
    return call.ast.fn_expr == callee;
}

/// The enum whose tags `@tagName(x)` at `node` names one of: `x`'s, a value of it or a
/// capture of a `switch` prong on one.
fn tagNamesOf(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Container {
    const tree = &self.project.at(file).file.tree;
    const at = ungrouped(tree, node);
    if (!isBuiltin(tree, at, "@tagName")) return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, at, &buffer);
    if (args.len != 1) return null;
    const operand = ungrouped(tree, args[0]);
    if (enumOf(try self.resolveIn(env, file, operand))) |k| return k;
    if (tree.nodeTag(operand) != .identifier) return null;
    const record = self.declarationAt(file, operand) orelse return null;
    if (record.kind != .capture) return null;
    const model = &self.project.at(file).model;
    var up = record.node;
    while (tree.fullSwitchCase(up) == null) up = model.parentOf(up) orelse return null;
    const choice = tree.fullSwitch(model.parentOf(up) orelse return null) orelse return null;
    return enumOf(try self.resolveIn(env, file, choice.ast.condition));
}

/// The enum a value is of, or is.
fn enumOf(value: Value) ?Container {
    return switch (value) {
        .instance, .container => |k| k,
        .pointer => |inner| enumOf(inner.child.*),
        else => null,
    };
}

/// The names a `@field` name is one of: the field names of `subject`, a type whose struct,
/// union or enum information (`info`, `@typeInfo(subject).@"struct"`) the name ranges over
/// (`inline for (info.field_names) |name|`, the input at the capture's position), indexes
/// (`info.field_names[j]`), or is the `name` of an element of `info.fields`, or a tag `@tagName`
/// gives of a value declared of the subject; the list and the
/// information named in place, through constants, or by a capture of a `switch` on or an `if`
/// over `@typeInfo(subject)`.
const NamesOf = struct { subject: Ast.Node.Index, info: Ast.Node.Index };

fn namesOf(self: *Facts, file: Project.FileId, node: Ast.Node.Index, depth: usize) ResolveError!?NamesOf {
    if (depth > 8) return null;
    const tree = &self.project.at(file).file.tree;
    const at = ungrouped(tree, node);
    switch (tree.nodeTag(at)) {
        .identifier => {
            const record = self.declarationAt(file, at) orelse return null;
            switch (record.kind) {
                .variable => return self.namesOf(file, constInit(tree, record) orelse return null, depth + 1),
                .capture => return self.listOf(file, self.loopInput(file, record) orelse return null, "field_names", depth + 1),
                else => return null,
            }
        },
        .array_access => return self.listOf(file, tree.nodeData(at).node_and_node[0], "field_names", depth + 1),
        // `@tagName(x)`: a tag of the type `x` is declared with.
        .builtin_call_two, .builtin_call_two_comma => {
            if (!isBuiltin(tree, at, "@tagName")) return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = builtinArgs(tree, at, &buffer);
            if (args.len != 1) return null;
            const operand = ungrouped(tree, args[0]);
            if (tree.nodeTag(operand) != .identifier) return null;
            const d = (self.project.at(file).model.reference(operand) orelse return null).declaration orelse return null;
            const record = self.project.at(file).model.declarations[@backingInt(d)];
            const declared: ?Ast.Node.Index = switch (record.kind) {
                .parameter => self.parameterTypeNode(.{ .file = file, .index = d }),
                .variable => (tree.fullVarDecl(record.node) orelse return null).ast.type_node.unwrap(),
                else => null,
            };
            return .{ .subject = declared orelse return null, .info = at };
        },
        .field_access => {
            const item, const name_token = tree.nodeData(at).node_and_token;
            if (!std.mem.eql(u8, try self.memberName(tree.tokenSlice(name_token)), "name")) return null;
            const inner = ungrouped(tree, item);
            if (tree.nodeTag(inner) == .array_access) return self.listOf(file, tree.nodeData(inner).node_and_node[0], "fields", depth + 1);
            if (tree.nodeTag(inner) != .identifier) return null;
            const record = self.declarationAt(file, inner) orelse return null;
            if (record.kind != .capture) return null;
            return self.listOf(file, self.loopInput(file, record) orelse return null, "fields", depth + 1);
        },
        else => return null,
    }
}

/// The information whose `member` list `node` is (`info.field_names`, through constants).
fn listOf(self: *Facts, file: Project.FileId, node: Ast.Node.Index, comptime list: []const u8, depth: usize) ResolveError!?NamesOf {
    if (depth > 8) return null;
    const tree = &self.project.at(file).file.tree;
    const at = ungrouped(tree, node);
    switch (tree.nodeTag(at)) {
        .identifier => {
            const record = self.declarationAt(file, at) orelse return null;
            if (record.kind != .variable) return null;
            return self.listOf(file, constInit(tree, record) orelse return null, list, depth + 1);
        },
        .field_access => {
            const info, const token = tree.nodeData(at).node_and_token;
            if (!std.mem.eql(u8, try self.memberName(tree.tokenSlice(token)), list)) return null;
            return .{ .subject = (try self.infoSubject(file, info, depth + 1)) orelse return null, .info = info };
        },
        else => return null,
    }
}

/// The type `node` is the struct, union or enum information of: `@typeInfo(S).@"struct"`, in
/// place, through constants, or a `switch` prong's capture of `@typeInfo(S)`.
fn infoSubject(self: *Facts, file: Project.FileId, node: Ast.Node.Index, depth: usize) ResolveError!?Ast.Node.Index {
    if (depth > 8) return null;
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    const at = ungrouped(tree, node);
    switch (tree.nodeTag(at)) {
        .identifier => {
            const record = self.declarationAt(file, at) orelse return null;
            switch (record.kind) {
                .variable => return self.infoSubject(file, constInit(tree, record) orelse return null, depth + 1),
                .capture => {
                    // `switch (@typeInfo(S)) { .@"struct" => |info| ... }`
                    var up = record.node;
                    const case = while (true) {
                        if (tree.fullSwitchCase(up)) |found| break found;
                        up = model.parentOf(up) orelse return null;
                    };
                    if (case.payload_token == null or case.payload_token.? + @intFromBool(tree.tokenTag(case.payload_token.?) == .asterisk) != record.token) return null;
                    const choice = tree.fullSwitch(model.parentOf(up) orelse return null) orelse return null;
                    return typeInfoOperand(tree, choice.ast.condition);
                },
                else => return null,
            }
        },
        .field_access => {
            const info, const token = tree.nodeData(at).node_and_token;
            const kind = try self.memberName(tree.tokenSlice(token));
            if (!std.mem.eql(u8, kind, "struct") and !std.mem.eql(u8, kind, "union") and !std.mem.eql(u8, kind, "enum")) return null;
            const inner = ungrouped(tree, info);
            if (typeInfoOperand(tree, inner)) |subject| return subject;
            if (tree.nodeTag(inner) != .identifier) return null;
            const record = self.declarationAt(file, inner) orelse return null;
            if (record.kind != .variable) return null;
            return typeInfoOperand(tree, ungrouped(tree, constInit(tree, record) orelse return null));
        },
        else => return null,
    }
}

/// `S` of `@typeInfo(S)`.
fn typeInfoOperand(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@typeInfo")) return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, node, &buffer);
    return if (args.len == 1) args[0] else null;
}

/// Whether `@field(holder, name)` names no declaration because its name is one of the field or
/// tag names of what the holder is or holds (`namesOf`, `namesNoDeclaration`): what P006 and
/// the forward walk read alike.
pub fn fieldNameOwn(self: *Facts, file: Project.FileId, holder: Ast.Node.Index, name: Ast.Node.Index) ResolveError!bool {
    const names = (try self.namesOf(file, name, 0)) orelse return false;
    return self.namesNoDeclaration(file, holder, names);
}

/// Whether `node` names a `var`.
fn namesVar(self: *const Facts, file: Project.FileId, node: Ast.Node.Index) bool {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(node) != .identifier) return false;
    const record = self.declarationAt(file, node) orelse return false;
    if (record.kind != .variable) return false;
    const variable = tree.fullVarDecl(record.node) orelse return false;
    return tree.tokenTag(variable.ast.mut_token) == .keyword_var;
}

/// Whether `@field(holder, name)`, the name one of `names`' subject's field names, names no
/// declaration: the holder is the subject itself, a value of it (`@TypeOf(holder)` is the
/// subject, or the holder is declared of it or a pointer to it), or its tag type
/// (`info.tag_type`); Zig refuses a declaration named as a field or a tag of its container.
fn namesNoDeclaration(self: *Facts, file: Project.FileId, holder: Ast.Node.Index, names: NamesOf) bool {
    const tree = &self.project.at(file).file.tree;
    const h = ungrouped(tree, holder);
    const subject = self.throughConsts(file, names.subject);
    // A type written as a `var` (`comptime var X: type = S;`) is one declaration that holds a
    // type, then another: no identity of a type. Its value's type (`@TypeOf(x)`) is fixed.
    const fixed = !self.namesVar(file, ungrouped(tree, names.subject)) and !self.namesVar(file, subject);
    if (fixed and self.sameTypeWritten(file, h, names.subject)) return true;
    if (typeOfOperand(tree, subject)) |operand| {
        if (self.sameName(file, h, ungrouped(tree, operand))) return true;
        // `@TypeOf(out.*)`: `out` points at the value.
        if (tree.nodeTag(operand) == .deref and self.sameName(file, h, ungrouped(tree, tree.nodeData(operand).node))) return true;
    }
    // A field declared of the subject (`value: @TypeOf(value)`) read off a value.
    if (tree.nodeTag(h) == .field_access) {
        const of, const member_token = tree.nodeData(h).node_and_token;
        const field = self.fieldTypeNode(file, ungrouped(tree, of), tree.tokenSlice(member_token)) orelse return false;
        if (field.file != file) return false;
        return fixed and self.sameWrittenType(file, field.node, names.subject);
    }
    if (tree.nodeTag(h) != .identifier) return false;
    const record = self.declarationAt(file, h) orelse return false;
    switch (record.kind) {
        .parameter => if (self.parameterTypeNode(.{ .file = file, .index = (self.project.at(file).model.reference(h) orelse return false).declaration.? })) |t| {
            if (fixed and self.sameTypeWritten(file, writtenPointee(tree, t), names.subject)) return true;
        },
        .variable => if (tree.fullVarDecl(record.node)) |variable| {
            if (variable.ast.type_node.unwrap()) |t| if (fixed and self.sameTypeWritten(file, writtenPointee(tree, t), names.subject)) return true;
            if (self.tagTypeOf(file, variable.ast.init_node.unwrap() orelse return false, names.info)) return true;
        },
        .capture => {
            // `if (info.tag_type) |Tag|`
            var up = record.node;
            while (true) {
                if (tree.fullIf(up)) |branch| {
                    if (branch.payload_token == record.token) return self.tagTypeOf(file, branch.ast.cond_expr, names.info);
                    return false;
                }
                up = self.project.at(file).model.parentOf(up) orelse return false;
            }
        },
        else => {},
    }
    return false;
}

/// Whether a `@field(holder, name)` stands where `name` is known to be a field of
/// `@TypeOf(holder)`: in the `then` of an `if` one of whose `and`ed conditions is
/// `@hasField(@TypeOf(holder), name)`, or after a statement of a block holding it that refuses
/// compilation otherwise (`if (!@hasField(@TypeOf(holder), name)) @compileError(…)`, or a
/// constant `std.meta.fieldIndex(@TypeOf(holder), name) orelse @compileError(…)`). Were the
/// holder a type, `@TypeOf(holder)` is `type`, which has no field: that instantiation does not
/// compile, so the name names a field of the value in each one that does, bound or not.
fn fieldGuarded(self: *Facts, file: Project.FileId, holder: Ast.Node.Index, name: Ast.Node.Index) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var child = holder;
    var at = model.parentOf(holder) orelse return false;
    while (true) {
        switch (tree.nodeTag(at)) {
            .fn_decl => return false,
            else => {},
        }
        if (tree.fullIf(at)) |branch| if (branch.ast.then_expr == child and try self.hasFieldOf(file, branch.ast.cond_expr, holder, name, true)) return true;
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.blockStatements(&buffer, at)) |statements| for (statements) |statement| {
            if (statement == child) break;
            if (try self.refusesUnlessField(file, statement, holder, name)) return true;
        };
        child = at;
        at = model.parentOf(at) orelse return false;
    }
}

/// Whether a statement refuses compilation unless `name` is a field of `@TypeOf(holder)`.
fn refusesUnlessField(self: *Facts, file: Project.FileId, statement: Ast.Node.Index, holder: Ast.Node.Index, name: Ast.Node.Index) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    if (tree.fullIf(statement)) |branch| {
        if (branch.ast.else_expr != .none) return false;
        const cond = ungrouped(tree, branch.ast.cond_expr);
        if (tree.nodeTag(cond) != .bool_not) return false;
        return refuses(tree, branch.ast.then_expr) and try self.hasFieldOf(file, tree.nodeData(cond).node, holder, name, false);
    }
    const variable = tree.fullVarDecl(statement) orelse return false;
    var init = ungrouped(tree, variable.ast.init_node.unwrap() orelse return false);
    if (tree.nodeTag(init) == .@"comptime") init = ungrouped(tree, tree.nodeData(init).node);
    if (tree.nodeTag(init) != .@"orelse") return false;
    const index, const otherwise = tree.nodeData(init).node_and_node;
    if (!refuses(tree, otherwise)) return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, ungrouped(tree, index)) orelse return false;
    if (call.ast.params.len != 2) return false;
    const callee = switch (try self.resolve(file, call.ast.fn_expr)) {
        .function => |decl| decl,
        else => return false,
    };
    const field_index = switch (try self.stdMember(&.{ "meta", "fieldIndex" })) {
        .function => |decl| decl,
        else => return false,
    };
    if (!std.meta.eql(callee, field_index)) return false;
    return self.ownType(file, call.ast.params[0], holder) and self.sameNameOrText(file, call.ast.params[1], name);
}

/// Whether `node` is `@compileError(…)`, alone or as a block's only statement.
fn refuses(tree: *const Ast, node: Ast.Node.Index) bool {
    var at = ungrouped(tree, node);
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, at)) |statements| {
        if (statements.len != 1) return false;
        at = ungrouped(tree, statements[0]);
    }
    return isBuiltin(tree, at, "@compileError");
}

/// Whether `cond` is, or (with `conjuncts`) `and`s, `@hasField(@TypeOf(holder), name)`.
fn hasFieldOf(self: *Facts, file: Project.FileId, cond: Ast.Node.Index, holder: Ast.Node.Index, name: Ast.Node.Index, conjuncts: bool) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    const at = ungrouped(tree, cond);
    if (conjuncts and tree.nodeTag(at) == .bool_and) {
        const left, const right = tree.nodeData(at).node_and_node;
        return try self.hasFieldOf(file, left, holder, name, true) or try self.hasFieldOf(file, right, holder, name, true);
    }
    if (!isBuiltin(tree, at, "@hasField")) return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, at, &buffer);
    return args.len == 2 and self.ownType(file, args[0], holder) and self.sameNameOrText(file, args[1], name);
}

/// Whether `node` is `@TypeOf(holder)`, in place or through constants.
fn ownType(self: *Facts, file: Project.FileId, node: Ast.Node.Index, holder: Ast.Node.Index) bool {
    const tree = &self.project.at(file).file.tree;
    const operand = typeOfOperand(tree, self.throughConsts(file, node)) orelse return false;
    return self.sameName(file, ungrouped(tree, operand), ungrouped(tree, holder));
}

/// Whether two names name one declaration, or are one string literal.
fn sameNameOrText(self: *const Facts, file: Project.FileId, a: Ast.Node.Index, b: Ast.Node.Index) bool {
    const tree = &self.project.at(file).file.tree;
    const one = ungrouped(tree, a);
    const other = ungrouped(tree, b);
    if (self.sameName(file, one, other)) return true;
    return tree.nodeTag(one) == .string_literal and tree.nodeTag(other) == .string_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(one)), tree.tokenSlice(tree.nodeMainToken(other)));
}

/// The type written for field `name` of what `of` is declared as (a parameter or a variable
/// of a container type, or a pointer to one), with its file.
fn fieldTypeNode(self: *Facts, file: Project.FileId, of: Ast.Node.Index, name: []const u8) ?Key {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(of) != .identifier) return null;
    const d = (self.project.at(file).model.reference(of) orelse return null).declaration orelse return null;
    const record = self.project.at(file).model.declarations[@backingInt(d)];
    const declared_as = switch (record.kind) {
        .parameter => self.parameterTypeNode(.{ .file = file, .index = d }) orelse return null,
        .variable => (tree.fullVarDecl(record.node) orelse return null).ast.type_node.unwrap() orelse return null,
        else => return null,
    };
    const container = switch (self.resolve(file, writtenPointee(tree, declared_as)) catch return null) {
        .container => |k| k,
        else => return null,
    };
    const field = self.member(container, name) orelse return null;
    const field_record = self.project.at(field.file).model.declarations[@backingInt(field.index)];
    if (field_record.kind != .field) return null;
    const field_tree = &self.project.at(field.file).file.tree;
    const declared = field_tree.fullContainerField(field_record.node) orelse return null;
    return .{ .file = field.file, .node = declared.ast.type_expr.unwrap() orelse return null };
}

/// Whether two type expressions of one file name one type by how they are written: one name,
/// or `@TypeOf` of one name.
fn sameWrittenType(self: *Facts, file: Project.FileId, a: Ast.Node.Index, b: Ast.Node.Index) bool {
    const tree = &self.project.at(file).file.tree;
    const one = self.throughConsts(file, a);
    const other = self.throughConsts(file, b);
    if (self.sameName(file, one, other)) return true;
    const x = typeOfOperand(tree, one) orelse return false;
    const y = typeOfOperand(tree, other) orelse return false;
    return self.sameName(file, ungrouped(tree, x), ungrouped(tree, y));
}

/// Whether `node` is the tag type of the information `info` (`info.tag_type`, `.?`, or the
/// left of `orelse`).
fn tagTypeOf(self: *Facts, file: Project.FileId, node: Ast.Node.Index, info: Ast.Node.Index) bool {
    const tree = &self.project.at(file).file.tree;
    var at = ungrouped(tree, node);
    while (true) switch (tree.nodeTag(at)) {
        .unwrap_optional => at = ungrouped(tree, tree.nodeData(at).node_and_token[0]),
        .@"orelse" => at = ungrouped(tree, tree.nodeData(at).node_and_node[0]),
        else => break,
    };
    if (tree.nodeTag(at) != .field_access) return false;
    const of, const token = tree.nodeData(at).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(token), "tag_type")) return false;
    return self.sameName(file, ungrouped(tree, of), ungrouped(tree, info));
}

/// What a type written as `node` points at or holds: `*S`, `*const S`, `?S`, `[]S` give `S`.
fn writtenPointee(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = ungrouped(tree, node);
    while (true) {
        if (tree.fullPtrType(at)) |pointer| {
            at = ungrouped(tree, pointer.ast.child_type);
            continue;
        }
        if (tree.nodeTag(at) == .optional_type) {
            at = ungrouped(tree, tree.nodeData(at).node);
            continue;
        }
        return at;
    }
}

/// `node` with the constants that name it followed (`const T = @TypeOf(value)` gives
/// `@TypeOf(value)`).
fn throughConsts(self: *Facts, file: Project.FileId, node: Ast.Node.Index) Ast.Node.Index {
    const tree = &self.project.at(file).file.tree;
    var at = ungrouped(tree, node);
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        if (tree.nodeTag(at) != .identifier) return at;
        const record = self.declarationAt(file, at) orelse return at;
        if (record.kind != .variable) return at;
        at = ungrouped(tree, constInit(tree, record) orelse return at);
    }
    return at;
}

/// `y` of `@TypeOf(y)`.
fn typeOfOperand(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@TypeOf")) return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, node, &buffer);
    return if (args.len == 1) args[0] else null;
}

/// Whether two type expressions name one type: one declaration, before or after the constants they
/// go through (`const S = struct { ... }` written `S` on both sides, or `const A = S;` on one), or
/// the one expression those constants reach.
fn sameTypeWritten(self: *Facts, file: Project.FileId, a: Ast.Node.Index, b: Ast.Node.Index) bool {
    const tree = &self.project.at(file).file.tree;
    const one = ungrouped(tree, a);
    const other = ungrouped(tree, b);
    if (self.sameName(file, one, other)) return true;
    const one_reached = self.throughConsts(file, one);
    const other_reached = self.throughConsts(file, other);
    return one_reached == other_reached or self.sameName(file, one_reached, other_reached);
}
/// Whether two names name one declaration, or two member reads one member of one such name
/// (`Container.asn1_tags`): what `@TypeOf` gives of them is one type.
fn sameName(self: *const Facts, file: Project.FileId, a: Ast.Node.Index, b: Ast.Node.Index) bool {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(a) == .field_access and tree.nodeTag(b) == .field_access) {
        const one, const one_member = tree.nodeData(a).node_and_token;
        const other, const other_member = tree.nodeData(b).node_and_token;
        return std.mem.eql(u8, tree.tokenSlice(one_member), tree.tokenSlice(other_member)) and self.sameName(file, ungrouped(tree, one), ungrouped(tree, other));
    }
    if (tree.nodeTag(a) != .identifier or tree.nodeTag(b) != .identifier) return false;
    const model = &self.project.at(file).model;
    const one = (model.reference(a) orelse return false).declaration orelse return false;
    const other = (model.reference(b) orelse return false).declaration orelse return false;
    return one == other;
}

/// The declaration a name refers to, in its file.
fn declarationAt(self: *const Facts, file: Project.FileId, node: Ast.Node.Index) ?Model.Declaration {
    const model = &self.project.at(file).model;
    const d = (model.reference(node) orelse return null).declaration orelse return null;
    return model.declarations[@backingInt(d)];
}

/// What a `const` declaration is initialized with; null for a `var`.
fn constInit(tree: *const Ast, record: Model.Declaration) ?Ast.Node.Index {
    const variable = tree.fullVarDecl(record.node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
    return variable.ast.init_node.unwrap();
}

/// The input a `for` capture takes, by its position among the captures.
fn loopInput(self: *const Facts, file: Project.FileId, record: Model.Declaration) ?Ast.Node.Index {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var at = record.node;
    const loop = while (true) {
        if (tree.fullFor(at)) |found| break found;
        at = model.parentOf(at) orelse return null;
    };
    const position = Model.capturePosition(tree, loop, record.token) orelse return null;
    return if (position < loop.ast.inputs.len) loop.ast.inputs[position] else null;
}

/// The names of a container's fields.
fn fieldNames(self: *Facts, container: Container) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const model = &self.project.at(container.file).model;
    for (model.declarations) |record| if (record.scope == container.scope and record.kind == .field) names.append(self.gpa, record.name) catch return names.items;
    return names.items;
}

/// Records a member name met on a holder that does not resolve (`Analysis.named`): Zig's member
/// lookup with the holder unknown, which may name any function or container-level constant so
/// named. The walk reads none of them; a reader's query does (`lazilyAnalyzed`).
fn reachNamed(self: *Facts, found: *Analysis, next: *std.ArrayList(PartRead), name: []const u8) ResolveError!void {
    _ = next;
    try found.named.put(self.gpa, name, {});
}

/// The part of a file Zig analyzes as one that holds `node`: its function (`fn_decl`, or an
/// `extern` prototype), its container-level constant (with the fields and members of a
/// container it declares outside their own functions and constants), its container-level
/// `comptime` block, or its test. Null: the file's own fields and loose parts.
/// Read once per file, in `partsOf`'s index.
fn partOf(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Ast.Node.Index {
    const part = (try self.partsOf(file)).of[@backingInt(node)];
    return if (part == .root) null else part;
}

/// `partOf` by the parent walk: what `partsOf`'s index holds for each node.
fn partWalk(self: *const Facts, file: Project.FileId, node: Ast.Node.Index) ?Ast.Node.Index {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var at = node;
    while (true) {
        switch (tree.nodeTag(at)) {
            .fn_decl, .test_decl => return at,
            .@"comptime" => if (containerLevel(tree, model, at)) return at,
            else => {
                if (tree.fullVarDecl(at) != null and containerLevel(tree, model, at)) return at;
                var buffer: [1]Ast.Node.Index = undefined;
                if (tree.fullFnProto(&buffer, at)) |proto| if (proto.name_token != null and containerLevel(tree, model, at)) return at;
            },
        }
        at = model.parentOf(at) orelse return null;
        if (at == .root) return null;
    }
}

/// Whether a declaration or a block is a member of a container: the file's or one written.
fn containerLevel(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    const parent = model.parentOf(node) orelse return true;
    if (parent == .root) return true;
    var buffer: [2]Ast.Node.Index = undefined;
    return tree.fullContainerDecl(&buffer, parent) != null;
}

/// A file's parts (`partOf`) with their nodes, and the part each function and container-level
/// constant is, found once.
fn partsOf(self: *Facts, file: Project.FileId) ResolveError!*const FileParts {
    if (self.file_parts.get(file)) |kept| return kept;
    // Boxed: a caller holds one while `partOf` indexes another file.
    const parts = try self.gpa.create(FileParts);
    parts.* = .{};
    const tree = &self.project.at(file).file.tree;
    const of = try self.gpa.alloc(Ast.Node.Index, tree.nodes.len);
    of[0] = .root;
    for (1..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        of[i] = self.partWalk(file, node) orelse .root;
        const group = try parts.nodes.getOrPut(self.gpa, of[i]);
        if (!group.found_existing) group.value_ptr.* = .empty;
        try group.value_ptr.append(self.gpa, node);
    }
    const model = &self.project.at(file).model;
    for (model.declarations, 0..) |record, d| {
        if (record.kind != .function and record.kind != .variable) continue;
        const part = of[@backingInt(record.node)];
        if (part == .root) continue;
        const is_own = switch (tree.nodeTag(part)) {
            .fn_decl => record.kind == .function and model.parentOf(record.node) == part,
            else => part == record.node,
        };
        if (is_own) try parts.declared.put(self.gpa, part, @fromBackingInt(@intCast(d)));
    }
    parts.of = of;
    try self.file_parts.put(self.gpa, file, parts);
    return parts;
}

/// The reading the call at `node` in `file` makes of `decl`, made in `env`: none where `env`
/// is none, an `@call`'s arguments are not known, or the chain is past 32 calls deep (each
/// binding's then).
pub fn readingAt(self: *Facts, file: Project.FileId, node: Ast.Node.Index, decl: Decl, env: ?*const Env) ResolveError!?*const Env {
    const outer = env orelse return null;
    if (outer.depth >= 32) return null;
    return self.readingFrom(file, node, decl, outer);
}

/// The reading the call at `node` makes of `decl`, made in `outer` or in none (a function read
/// once), at any depth (the walk bounds a declaration's readings by number): none where its
/// arguments or receiver are not known (`bindCall`).
pub fn readingFrom(self: *Facts, file: Project.FileId, node: Ast.Node.Index, decl: Decl, outer: ?*const Env) ResolveError!?*const Env {
    const call = (try calls.under(self, outer, file, node)) orelse return null;
    return switch (try self.bindCall(&call, decl, outer)) {
        .reading => |reading| reading,
        .unknown => null,
    };
}

/// Whether `node`, read in `env`, is a value, never a type, whatever its type: an address, a
/// dereference, a slice or a literal; a runtime `var` (Zig refuses one of type `type`); a
/// parameter neither `comptime` nor `anytype` (a `type` one must be `comptime`), or an
/// `anytype` one the reading binds to a value; a constant a value initializes, every branch
/// of a `switch` or an `if` a value; a field of a value (`@field(value, name)`).
fn valueIn(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index, depth: usize) ResolveError!bool {
    if (depth > 16) return false;
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var at = node;
    while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
    switch (tree.nodeTag(at)) {
        .address_of, .deref, .slice, .slice_open, .slice_sentinel, .string_literal, .multiline_string_literal, .number_literal, .char_literal => return true,
        .array_init_dot, .array_init_dot_comma, .array_init_dot_two, .array_init_dot_two_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init_dot_two, .struct_init_dot_two_comma => return true,
        .identifier => {},
        .builtin_call_two, .builtin_call_two_comma => {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(at)), "@field")) return false;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = builtinArgs(tree, at, &buffer);
            return args.len == 2 and try self.valueIn(env, file, args[0], depth + 1);
        },
        else => {
            if (tree.fullSwitch(at)) |choice| {
                for (choice.ast.cases) |case_node| {
                    const case = tree.fullSwitchCase(case_node) orelse return false;
                    if (!try self.valueIn(env, file, case.ast.target_expr, depth + 1)) return false;
                }
                return true;
            }
            if (tree.fullIf(at)) |branch| {
                const otherwise = branch.ast.else_expr.unwrap() orelse return false;
                return try self.valueIn(env, file, branch.ast.then_expr, depth + 1) and try self.valueIn(env, file, otherwise, depth + 1);
            }
            return false;
        },
    }
    const d = (model.reference(at) orelse return false).declaration orelse return false;
    const record = model.declarations[@backingInt(d)];
    switch (record.kind) {
        .variable => {
            const variable = tree.fullVarDecl(record.node) orelse return false;
            if (tree.tokenTag(variable.ast.mut_token) == .keyword_var) return variable.comptime_token == null;
            const init = variable.ast.init_node.unwrap() orelse return false;
            return self.valueIn(env, file, init, depth + 1);
        },
        .parameter => {
            const function = self.functionOf(.{ .file = file, .index = d }) orelse return false;
            var buffer: [1]Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(function.index)].node) orelse return false;
            var it = proto.iterate(tree);
            const position = while (it.next()) |param| {
                if (param.name_token != record.token) continue;
                if (param.type_expr != null) {
                    const marked = param.comptime_noalias orelse return true;
                    return tree.tokenTag(marked) != .keyword_comptime;
                }
                break self.parameterPosition(file, function, record.token) orelse return false;
            } else return false;
            // `anytype`: a value where the reading binding it was handed one, by the
            // argument's expression in the reading its call is in (`Env.values`).
            var reading = env;
            while (reading) |r| : (reading = r.outer) {
                if (!std.meta.eql(r.function, function)) continue;
                if (position >= r.values.len) return false;
                return r.values[position];
            }
            return false;
        },
        else => return false,
    }
}

/// The container whose field or tag names `node` is one of (`namesOf`), where the program
/// declares it: what a name drawn from its type information's `field_names` or `fields` may be.
fn fieldNamesOf(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Container {
    const names = (try self.namesOf(file, node, 0)) orelse return null;
    if (self.namesVar(file, self.throughConsts(file, names.subject))) return null;
    return switch (try self.resolve(file, names.subject)) {
        .container => |found| found,
        else => null,
    };
}

/// Whether `container` declares a field `name`.
fn hasField(self: *const Facts, container: Container, name: []const u8) bool {
    const found = self.member(container, name) orelse return false;
    return self.project.at(found.file).model.declarations[@backingInt(found.index)].kind == .field;
}

/// Whether `node` is a type: one that resolves to a container, or a parameter declared `type`.
fn isType(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    if (try self.resolve(file, node) == .container) return true;
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    if (tree.nodeTag(node) != .identifier) return false;
    const decl = (model.reference(node) orelse return false).declaration orelse return false;
    if (model.declarations[@backingInt(decl)].kind != .parameter) return false;
    const kind = self.parameterTypeNode(.{ .file = file, .index = decl }) orelse return false;
    return tree.nodeTag(kind) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(kind)), "type");
}

/// Adds what `node`, stored in a function-pointer field, may call: the function it names
/// (`f`, `&f`), or each a per-build choice names; false where it is anything else.
fn stores(self: *Facts, targets: *std.ArrayList(Value), file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    var value = try self.resolve(file, node);
    if (value == .pointer and value.pointer.child.* == .function) value = value.pointer.child.*;
    const each: []const Value = switch (value) {
        .function => &.{value},
        .alternatives => |choices| choices,
        else => return false,
    };
    for (each) |one| {
        if (one != .function) return false;
        for (targets.items) |known| {
            if (std.meta.eql(known.function, one.function)) break;
        } else try targets.append(self.gpa, one);
    }
    return true;
}

/// Files by their ids.
const Files = std.AutoHashMapUnmanaged(Project.FileId, void);

/// The files that may share a compilation with `file`: each a root that reaches it may build,
/// so all its imports reach, by the program's import edges. A store in any other file is in
/// another program, where no call of this one goes.
fn compiledWith(self: *Facts, file: Project.FileId) ResolveError!*const Files {
    if (self.compiled_with.getPtr(file)) |known| return known;
    var roots: Files = .empty;
    try roots.put(self.gpa, file, {});
    var growing = true;
    while (growing) {
        growing = false;
        for (self.project.imports) |edge| if (roots.contains(edge.target) and !roots.contains(edge.from)) {
            try roots.put(self.gpa, edge.from, {});
            growing = true;
        };
    }
    var reached: Files = .empty;
    var it = roots.keyIterator();
    while (it.next()) |root| try reached.put(self.gpa, root.*, {});
    growing = true;
    while (growing) {
        growing = false;
        for (self.project.imports) |edge| if (reached.contains(edge.from) and !reached.contains(edge.target)) {
            try reached.put(self.gpa, edge.target, {});
            growing = true;
        };
    }
    const kept = try self.compiled_with.getOrPut(self.gpa, file);
    kept.value_ptr.* = reached;
    return kept.value_ptr;
}

/// Whether every `@import` `file` makes names a file the program holds: one of a computed name,
/// or a name no mapping gives (Zig's own per-build files and names the build declares absent
/// aside), may hold a store the program does not show.
fn importsRead(self: *Facts, file: Project.FileId) ResolveError!bool {
    if (self.imports_read.get(file)) |known| return known;
    const tree = &self.project.at(file).file.tree;
    const read = for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
        .builtin_call_two, .builtin_call_two_comma => {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) continue;
            switch (try self.resolve(file, node)) {
                .unknown => |why| switch (why) {
                    .absent, .zig_own => {},
                    else => break false,
                },
                else => {},
            }
        },
        else => {},
    } else true;
    try self.imports_read.put(self.gpa, file, read);
    return read;
}

/// A pointer's `len` or `ptr` where what it points at has no such member: a slice's or an
/// array's length, a number, and its many-item pointer.
fn sequence(pointer: Value, name: []const u8) Value {
    if (std.mem.eql(u8, name, "len")) return .scalar;
    if (std.mem.eql(u8, name, "ptr")) return pointer;
    return .{ .unknown = .unsupported };
}

/// A call to a function whose result is written in terms of one of its own `comptime T: type`
/// parameters, such as `std.mem.zeroes(T)` or `gpa.create(T)`, returns that result with `T` the
/// type the call passes there. A call through a namespace or by name, or a method called on a
/// value, whose first parameter that value is.
fn typeArgument(self: *Facts, file: Project.FileId, call: Ast.full.Call, decl: Decl) ResolveError!?Value {
    const tree = &self.project.at(file).file.tree;
    // A method called on a value takes that value as its first parameter.
    var receiver: usize = 0;
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        switch (try self.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
            .container => {},
            .instance => receiver = 1,
            .pointer => |p| if (p.child.* == .instance) {
                receiver = 1;
            } else return null,
            else => return null,
        }
    } else if (tree.nodeTag(call.ast.fn_expr) != .identifier) return null;
    const model = &self.project.at(decl.file).model;
    const target_tree = &self.project.at(decl.file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, model.declarations[@backingInt(decl.index)].node) orelse return null;
    const result_node = function.ast.return_type.unwrap() orelse return null;
    const generic: Generic = .{ .file = file, .call = call, .decl = decl, .function = function, .receiver = receiver };
    const result = (try self.written(generic, result_node, 0)) orelse return null;
    // `!T`: an error union whose error set the body infers.
    if (Model.inferredErrors(target_tree, result_node)) return .{ .error_union = try self.boxed(result) };
    return result;
}

/// A generic function called: where, how and what it declares.
const Generic = struct { file: Project.FileId, call: Ast.full.Call, decl: Decl, function: Ast.full.FnProto, receiver: usize };

/// A result type written in terms of a `comptime T: type` parameter (`T`, `*T`, `?T`, `[]T`,
/// `[N]T`, `E!*T`), with the call's argument for `T`; null for any other result.
fn written(self: *Facts, generic: Generic, node: Ast.Node.Index, depth: usize) ResolveError!?Value {
    if (depth == 16) return null;
    const model = &self.project.at(generic.decl.file).model;
    const target_tree = &self.project.at(generic.decl.file).file.tree;
    if (target_tree.fullPtrType(node)) |ptr| {
        const child = (try self.written(generic, ptr.ast.child_type, depth + 1)) orelse return null;
        return try self.pointerTo(child, ptr.size);
    }
    if (target_tree.fullArrayType(node)) |array| {
        const child = (try self.written(generic, array.ast.elem_type, depth + 1)) orelse return null;
        return .{ .array = try self.boxed(child) };
    }
    switch (target_tree.nodeTag(node)) {
        .optional_type => {
            const child = (try self.written(generic, target_tree.nodeData(node).node, depth + 1)) orelse return null;
            return .{ .optional = try self.boxed(child) };
        },
        .error_union => {
            const child = (try self.written(generic, target_tree.nodeData(node).node_and_node[1], depth + 1)) orelse return null;
            return .{ .error_union = try self.boxed(child) };
        },
        .identifier => {},
        else => return null,
    }
    const ref = model.reference(node) orelse return null;
    const index = ref.declaration orelse return null;
    const parameter = model.declarations[@backingInt(index)];
    if (parameter.kind != .parameter) return null;
    var it = generic.function.iterate(target_tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (param.name_token != parameter.token) continue;
        const comptime_token = param.comptime_noalias orelse return null;
        if (target_tree.tokenTag(comptime_token) != .keyword_comptime) return null;
        const type_expr = param.type_expr orelse return null;
        if (target_tree.nodeTag(type_expr) != .identifier or !std.mem.eql(u8, target_tree.tokenSlice(target_tree.nodeMainToken(type_expr)), "type")) return null;
        if (position < generic.receiver or position - generic.receiver >= generic.call.ast.params.len) return null;
        return try self.instance(try self.resolve(generic.file, generic.call.ast.params[position - generic.receiver]));
    }
    return null;
}

/// A method of a container a type function made, called on a value of it: its declared result
/// with the type function's parameters read as the arguments of the call that made it, as
/// `Inbox(Message).takeAll` returning `?*T` returns `?*Message`.
fn madeResult(self: *Facts, file: Project.FileId, call: Ast.full.Call, decl: Decl) ResolveError!?Value {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    return self.madeResultOn(try self.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0]), decl);
}

/// A method called on one of several receivers, each a made container's (`if (T == bool)
/// &memo.found else &memo.needed`): what each one's method gives, read with that receiver's
/// bindings. Null where a receiver is no made container's or its method does not resolve so.
fn eachReceiver(self: *Facts, file: Project.FileId, call: Ast.full.Call) ResolveError!?Value {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const data = tree.nodeData(call.ast.fn_expr).node_and_token;
    const receiver = try self.resolve(file, data[0]);
    if (receiver != .alternatives) return null;
    const name = tree.tokenSlice(data[1]);
    const each = try self.gpa.alloc(Value, receiver.alternatives.len);
    for (receiver.alternatives, each) |one, *out| {
        const container = switch (one) {
            .instance, .container => |c| c,
            .pointer => |p| switch (p.child.*) {
                .instance, .container => |c| c,
                else => return null,
            },
            else => return null,
        };
        const method = self.member(container, name) orelse return null;
        if (self.project.at(method.file).model.declarations[@backingInt(method.index)].kind != .function) return null;
        out.* = (try self.madeResultOn(one, method)) orelse return null;
        if (unknownWithin(out.*)) return null;
    }
    return try self.choose(each);
}

/// `madeResult` of the method `decl` called on `receiver`.
fn madeResultOn(self: *Facts, receiver: Value, decl: Decl) ResolveError!?Value {
    // A method called on a value of it, or a function called through the made type itself
    // (`Held.initFrom(source)` of `const Held = Owned(Payload, release)`).
    const container = switch (receiver) {
        .instance, .container => |c| c,
        .pointer => |p| switch (p.child.*) {
            .instance, .container => |c| c,
            else => return null,
        },
        else => return null,
    };
    const made = container.made_by orelse return null;
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (decl.file != container.file or record.scope != container.scope) return null;
    const target_tree = &self.project.at(decl.file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, record.node) orelse return null;
    const result_node = function.ast.return_type.unwrap() orelse return null;
    // A type function declared in it makes its own container: read as a template.
    if (typeKeyword(target_tree, result_node)) return null;
    // A result written in terms of the method's own generic parameters (`Result(parser)`) is
    // this call's: the container's bindings alone would read them as every call's.
    if (namesGenericParameter(target_tree, function, result_node)) return null;
    var result = try self.substituted(decl.file, result_node, made);
    if (result == .unknown) return null;
    // A container declared beside the receiver's own in what the call made (an iterator's
    // `Entry`, declared in the map) is made by the same call.
    result = try self.madeWithin(result, self.madeOuter(container, made), made);
    if (Model.inferredErrors(target_tree, result_node)) return .{ .error_union = try self.boxed(try self.instance(result)) };
    return try self.instance(result);
}

/// `value` with every container declared inside `outer` (a made container's guard, its
/// record type), also behind pointers, optionals, error unions and arrays, made by the same
/// call as `outer`.
fn madeWithin(self: *Facts, value: Value, outer: Container, made: *const Made) ResolveError!Value {
    return switch (value) {
        .container => |inner| if (self.within(inner, outer) and !try self.madeInside(inner, outer)) .{ .container = .{ .file = inner.file, .scope = inner.scope, .symbolic = inner.symbolic, .made_by = made } } else value,
        .instance => |inner| if (self.within(inner, outer) and !try self.madeInside(inner, outer)) .{ .instance = .{ .file = inner.file, .scope = inner.scope, .symbolic = inner.symbolic, .made_by = made } } else value,
        .pointer => |to| try self.pointerTo(try self.madeWithin(to.child.*, outer, made), to.size),
        .optional => |to| .{ .optional = try self.boxed(try self.madeWithin(to.*, outer, made)) },
        .error_union => |to| .{ .error_union = try self.boxed(try self.madeWithin(to.*, outer, made)) },
        .array => |to| .{ .array = try self.boxed(try self.madeWithin(to.*, outer, made)) },
        else => value,
    };
}

/// Whether a container inside `outer` was made by a call of a type function declared inside
/// it (`FieldIterator(V)`), whose own bindings it keeps, the outer ones read through them.
fn madeInside(self: *Facts, inner: Container, outer: Container) ResolveError!bool {
    const made = inner.made_by orelse return false;
    const record = self.project.at(made.function.file).model.declarations[@backingInt(made.function.index)];
    if (made.function.file != outer.file) return false;
    return self.within(.{ .file = outer.file, .scope = record.scope }, outer);
}

/// The outermost container around `container` that a type function returns: the one its
/// call made, of which `container` (an iterator, a guard) is a part. A type function's
/// container sits in its body, whose scope is no container's.
fn madeOuter(self: *const Facts, container: Container, made: *const Made) Container {
    const model = &self.project.at(container.file).model;
    var outer = container.scope;
    while (model.scopes[@backingInt(outer)].parent) |parent| {
        const scope = model.scopes[@backingInt(parent)];
        // A file's own scope holds no type function's container.
        if (scope.kind != .container or scope.parent == null) break;
        outer = parent;
    }
    return .{ .file = container.file, .scope = outer, .symbolic = container.symbolic, .made_by = made };
}

fn within(self: *const Facts, inner: Container, outer: Container) bool {
    if (inner.file != outer.file) return false;
    // The made container itself (`Self`), as a method's result names it.
    if (inner.scope == outer.scope) return true;
    const scopes = self.project.at(inner.file).model.scopes;
    var scope: ?Model.Scope.Id = scopes[@backingInt(inner.scope)].parent;
    while (scope) |s| : (scope = scopes[@backingInt(s)].parent) if (s == outer.scope) return true;
    return false;
}

/// A type expression written inside a type function's container, its parameters read as the
/// arguments of the call that made it: the same reading as a generic call's (`resolveIn`).
fn substituted(self: *Facts, file: Project.FileId, node: Ast.Node.Index, made: *const Made) ResolveError!Value {
    return self.resolveIn(try self.madeEnv(made), file, node);
}

/// The call that makes a type function's container, followed through type functions that
/// return another's call: the innermost one, read with the bindings of those around it.
fn making(self: *Facts, outer: Made) ResolveError!*const Made {
    var current = try self.gpa.create(Made);
    current.* = outer;
    for (0..8) |_| {
        const next = (try self.forwarded(current.function)) orelse break;
        const inner = try self.gpa.create(Made);
        inner.* = .{ .function = next.function, .file = current.function.file, .call = next.call, .via = current, .assumed = current.assumed };
        current = inner;
    }
    current.bound = try self.madeEnv(current);
    return current;
}

/// The call a type function's final `return` makes of another type function, when it
/// returns one: `return Owner(T, false, cleanup);`.
fn forwarded(self: *Facts, function: Decl) ResolveError!?struct { function: Decl, call: Ast.Node.Index } {
    const tree = &self.project.at(function.file).file.tree;
    const record = self.project.at(function.file).model.declarations[@backingInt(function.index)];
    if (record.kind != .function) return null;
    const returned = finalReturn(tree, &self.project.at(function.file).model, record) orelse return null;
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, returned) orelse return null;
    // A callee not known is followed no further: the container it makes is unknown too, as its
    // template is (`findTemplate`), so no binding read through it is taken as known.
    const callee = switch (try self.definition(function.file, call.ast.fn_expr)) {
        .decl => |d| d,
        .none, .unknown => return null,
    };
    const target = switch (try self.origin(callee)) {
        .decl => |d| d,
        .none, .unknown => return null,
    };
    if (self.project.at(target.file).model.declarations[@backingInt(target.index)].kind != .function) return null;
    return .{ .function = target, .call = returned };
}

/// The bindings of the call that made a container: the type function's parameters bound to its
/// arguments (read with the bindings of the reading that made it, if any). A parameter the
/// function passes on changed when it calls itself again is not the call's argument on that
/// path, so it stays unknown.
fn madeEnv(self: *Facts, made: *const Made) ResolveError!*const Env {
    if (made.reading) |reading| return reading;
    const call_tree = &self.project.at(made.file).file.tree;
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = call_tree.fullCall(&call_buffer, made.call).?;
    // The bindings of the reading the call is in: a calling reading's, or a forwarding type
    // function's call.
    const outer_env: ?*const Env = if (made.via) |via| try self.madeEnv(via) else made.env;
    // Read where the call was: under what its path settled.
    const outer = self.assumed;
    defer self.assumed = outer;
    self.assumed = made.assumed;
    const args = try self.gpa.alloc(Value, call.ast.params.len);
    const truths = try self.gpa.alloc(?bool, call.ast.params.len);
    const spelled = try self.gpa.alloc(?Spelled, call.ast.params.len);
    const values = try self.gpa.alloc(bool, call.ast.params.len);
    for (call.ast.params, args, truths, spelled, values, 0..) |param, *arg, *t, *spelling, *value, position| {
        spelling.* = try self.spelledIn(outer_env, made.file, param);
        const changed = try self.passedOnChanged(made.function, position);
        value.* = !changed and try self.valueIn(outer_env, made.file, param, 0);
        arg.* = if (changed)
            .{ .unknown = .comptime_dependent }
        else
            try self.boundArgument(if (outer_env) |env| try self.resolveIn(env, made.file, param) else try self.resolve(made.file, param));
        t.* = if (changed) null else self.truth(outer_env, made.file, param);
    }
    return self.keptReading(.{ .function = made.function, .args = args, .depth = if (outer_env) |e| e.depth +| 1 else 0, .nested = if (outer_env) |e| e.nested else 0, .truths = truths, .outer = self.enclosingReading(outer_env, made.function), .spelled = spelled, .values = values });
}

fn passedOnChanged(self: *const Facts, function: Decl, position: usize) ResolveError!bool {
    const tree = &self.project.at(function.file).file.tree;
    const fn_node = self.scopeNode(function);
    if (tree.nodeTag(fn_node) != .fn_decl) return false;
    const body = tree.nodeData(fn_node).node_and_node[1];
    var body_buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&body_buffer, body) orelse return false;
    if (statements.len == 0) return false;
    return self.recursion(function, body, statements[statements.len - 1], position) orelse false;
}

/// What calling `callee` returns: its declared result, or the container a type function makes.
pub fn callResult(self: *Facts, callee: Value, _: void) ResolveError!Value {
    if (callee == .function) {
        const decl = callee.function;
        const declaration_record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        const target_tree = &self.project.at(decl.file).file.tree;
        var fn_buffer: [1]Ast.Node.Index = undefined;
        const function = target_tree.fullFnProto(&fn_buffer, declaration_record.node).?;
        const result_node = function.ast.return_type.unwrap() orelse return .{ .unknown = .unsupported };
        // `!T`: an error union whose error set the body infers.
        if (Model.inferredErrors(target_tree, result_node)) {
            const payload_value = try self.resolve(decl.file, result_node);
            if (payload_value == .unknown) return payload_value;
            return .{ .error_union = try self.boxed(try self.instance(payload_value)) };
        }
        // A bare function type, which only comptime code returns: the function itself.
        if (bareFunctionType(target_tree, result_node)) if (try self.returnedFunction(decl, declaration_record)) |returned| return returned;
        const result = try self.resolve(decl.file, result_node);
        if (result == .primitive and std.mem.eql(u8, result.primitive, "type")) {
            var value = try self.template(decl) orelse return .{ .unknown = .comptime_dependent };
            if (value == .container) value.container.symbolic = function.ast.params.len != 0;
            return value;
        }
        return self.instance(result);
    }
    // A value of a function type (`comptime read: fn (u8) T`) or a pointer to one (a
    // vtable's `*const fn (...) T`, which a call reads through): what the type declares it
    // returns, whichever function is passed.
    const fn_type: ?Key = switch (callee) {
        .fn_type => |key| key,
        .pointer => |to| if (to.child.* == .fn_type) to.child.fn_type else null,
        else => null,
    };
    if (fn_type) |key| {
        const result = try self.resultOf(key);
        if (result == .unknown or (result == .primitive and std.mem.eql(u8, result.primitive, "type"))) return .{ .unknown = .comptime_dependent };
        return self.instance(result);
    }
    return .{ .unknown = .unresolved };
}

/// The payload of an optional or error union `value` is.
/// A payload seen through what wraps it: `x catch ...` and `x orelse ...` have the payload's
/// type, as `x.?` has, where the other side coerces to it; the peer type of both where the other
/// side wraps the payload itself (`opt orelse f()` with `f` returning `E!T` is an `E!T`, `x catch
/// null` a `?T`, `a orelse b` with `b` a `?T` another `?T`, as a chain `a orelse b orelse return`
/// unwraps). Both sides are read with `env`'s bindings.
fn unwrapped(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const sides = tree.nodeData(node).node_and_node;
    const wrapper: std.meta.Tag(Value) = if (tree.nodeTag(node) == .@"catch") .error_union else .optional;
    const inner = try self.payload(try self.resolveIn(env, file, sides[0]), wrapper);
    if (inner == .unknown or never(tree, sides[1])) return inner;
    const other = try self.resolveIn(env, file, sides[1]);
    return switch (other) {
        .error_union => .{ .error_union = try self.boxed(inner) },
        .optional => .{ .optional = try self.boxed(inner) },
        // A function or a pointer to one: either side's.
        else => if (!callable(inner)) inner else self.identity(try self.erased(inner), &.{ inner, other }),
    };
}

fn payload(self: *Facts, value: Value, wrapper: std.meta.Tag(Value)) ResolveError!Value {
    return switch (value) {
        .optional => |inner| if (wrapper == .optional) inner.* else .{ .unknown = .unsupported },
        .error_union => |inner| if (wrapper == .error_union) inner.* else .{ .unknown = .unsupported },
        // A choice that is not so wrapped (`void` off Linux) is a build in which this unwrap
        // does not compile: it is left out.
        .alternatives => |each| blk: {
            var kept: std.ArrayList(Value) = .empty;
            for (each) |one| if (one == wrapper or one == .unknown) try kept.append(self.gpa, try self.payload(one, wrapper));
            if (kept.items.len == 0) break :blk .{ .unknown = .unsupported };
            break :blk self.choose(kept.items);
        },
        .unknown => value,
        else => .{ .unknown = .unsupported },
    };
}

fn pointee(self: *Facts, value: Value, _: void) ResolveError!Value {
    return switch (value) {
        .pointer => |inner| inner.child.*,
        .alternatives => self.map(value, {}, pointee),
        .unknown => value,
        else => .{ .unknown = .unsupported },
    };
}

/// An element of `value`: of an array, a pointer to an array, a slice or a many-item pointer.
fn indexed(self: *Facts, value: Value, _: void) ResolveError!Value {
    return switch (value) {
        .array => |inner| inner.*,
        .pointer => |inner| switch (inner.child.*) {
            .array => |elements| elements.*,
            .literal => |literal| self.choose(try self.literalParts(literal)),
            else => inner.child.*,
        },
        // A tuple of no type of its own, named (`inline for (kinds) |kind|`): one of its parts.
        .literal => |literal| self.choose(try self.literalParts(literal)),
        .alternatives => self.map(value, {}, indexed),
        .unknown => value,
        else => .{ .unknown = .unsupported },
    };
}

/// A slice of `value`: a pointer to an array's elements, or to what the slice or pointer
/// points at, of a size the slicing alone does not say (bounds known as the program compiles
/// make a pointer to an array, others a slice).
fn sliced(self: *Facts, value: Value, _: void) ResolveError!Value {
    return switch (value) {
        .array => self.pointerTo(value, null),
        .pointer => |p| .{ .pointer = .{ .child = p.child, .size = null } },
        // Whatever is sliced, the slice is one (or a pointer to an array, of a length the
        // program compiles in): its `.len` is its count, its elements what it holds.
        .unknown => .{ .pointer = .{ .child = try self.boxed(value), .size = .slice } },
        // A string literal's bytes stay plain bytes.
        .scalar => value,
        .alternatives => self.map(value, {}, sliced),
        else => .{ .unknown = .unsupported },
    };
}

/// A `switch` or `if`-`else` expression: what its branches give, chosen as one. A branch
/// that gives no value of its own (`@compileError`, `unreachable`, `undefined`) or never
/// completes (`return`, `break`, `continue`, `@panic`, `@trap`) is left out; a `null` one
/// makes the others optional, an error value (`error.Name`) an error union.
fn branches(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.at(file).file.tree;
    var values: std.ArrayList(Value) = .empty;
    var peers: Peers = .{};
    if (tree.fullSwitch(node)) |whole| {
        const taken = try self.takenProng(env, file, whole);
        for (whole.ast.cases, 0..) |case, i| {
            if (taken) |t| if (!t.has(i)) continue;
            const branch = tree.fullSwitchCase(case).?.ast.target_expr;
            // A prong the path rules out: Zig analyses only the one a comptime operand takes.
            if (never(tree, branch) or try self.dead(file, branch)) continue;
            if (peers.literal(tree, branch)) continue;
            try values.append(self.gpa, try self.resolveIn(env, file, branch));
        }
    } else if (tree.fullIf(node)) |whole| {
        const otherwise = whole.ast.else_expr.unwrap() orelse return null;
        // A condition known at compile time: Zig analyses only the branch it takes.
        const taken: []const Ast.Node.Index = if (whole.payload_token == null and whole.error_token == null) if (try self.comptimeTruth(env, file, whole.ast.cond_expr)) |t|
            if (t) &.{whole.ast.then_expr} else &.{otherwise}
        else
            &.{ whole.ast.then_expr, otherwise } else &.{ whole.ast.then_expr, otherwise };
        for (taken) |branch| {
            if (never(tree, branch)) continue;
            if (peers.literal(tree, branch)) continue;
            try values.append(self.gpa, try self.resolveIn(env, file, branch));
        }
    } else return null;
    return try self.peeredChoice(values.items, peers);
}

/// The prongs a `switch` on type information may take where what it reads is known: on a
/// type's kind, the one naming it (`.@"union"`), else its `else`; on a pointer's size, the one
/// naming it (`.slice`), else the `else`. Zig analyses no other. An array may be a vector, which
/// reads as one: the `.array` prong or the `.vector` one. Null where the subject is anything
/// else, a kind has no prong, or a prong names its kind other than by a literal.
fn takenProng(self: *Facts, env: ?*const Env, file: Project.FileId, whole: Ast.full.Switch) ResolveError!?Taken {
    const tree = &self.project.at(file).file.tree;
    // Only type information or a pointer's size read off it decides: a subject written as
    // neither (`switch (tag)`) is not resolved, every prong taken, as one that does not
    // resolve to either is.
    if (!mayReflect(tree, whole.ast.condition)) return null;
    const subject = try self.resolveIn(env, file, whole.ast.condition);
    if (subject != .reflected) return null;
    // A pointer's size (`switch (info.size)`): the prong naming it, else the `else`.
    if (subject.reflected.at == .size) {
        const size = switch (subject.reflected.of.*) {
            .pointer => |p| p.size orelse return null,
            else => return null,
        };
        return .{ .one = (try self.prongOf(tree, whole, @tagName(size))) orelse return null };
    }
    if (subject.reflected.at != .info) return null;
    // A pointer (a slice among them), an optional, an error union or a function type is of
    // its kind whatever it holds (`std.meta.Child(*const T)`), a primitive of its own
    // (`kindOfType`); an array may be a vector, so it takes either prong.
    const kind = if (subject.reflected.of.* == .array) "array" else (try self.kindOfType(subject.reflected.of.*)) orelse return null;
    const one = (try self.prongOf(tree, whole, kind)) orelse return null;
    if (!std.mem.eql(u8, kind, "array")) return .{ .one = one };
    return .{ .one = one, .other = (try self.prongOf(tree, whole, "vector")) orelse return null };
}

/// Whether `node` is written as what may be type information or a pointer's size read off
/// it: `@typeInfo(...)`, or a member access named `size` (`info.size`). What it is, its value
/// decides (`takenProng`).
fn mayReflect(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@typeInfo"),
        .field_access => std.mem.eql(u8, tree.tokenSlice(tree.nodeData(node).node_and_token[1]), "size"),
        else => false,
    };
}

/// The prongs a `switch` on type information may take (`takenProng`): one, or two.
const Taken = struct {
    one: usize,
    other: ?usize = null,

    fn has(taken: Taken, case: usize) bool {
        return taken.one == case or taken.other == case;
    }
};

/// The prong of a `switch` on type information that a type of kind `kind` takes: the one
/// naming it, else the `else`. Null where it has none, or a prong names a kind other than by a
/// literal.
fn prongOf(self: *Facts, tree: *const Ast, whole: Ast.full.Switch, kind: []const u8) ResolveError!?usize {
    var otherwise: ?usize = null;
    for (whole.ast.cases, 0..) |case, i| {
        const full = tree.fullSwitchCase(case).?; // unreachable: a switch's cases are cases
        if (full.ast.values.len == 0) otherwise = i;
        for (full.ast.values) |item| {
            if (tree.nodeTag(item) != .enum_literal) return null;
            if (std.mem.eql(u8, try self.memberName(tree.tokenSlice(tree.nodeMainToken(item))), kind)) return i;
        }
    }
    return otherwise;
}

/// The `std.builtin.Type` tag of a type, where its kind is known. A pointer (a slice among them),
/// an optional, an error union or a function type is of its kind whatever it holds
/// (`std.meta.Child(*const T)`). An array is not: a vector reads as one. A value of a type in a
/// type's place (a field's type read as what it holds) is of its kind.
fn kindOfType(self: *Facts, of: Value) ResolveError!?[]const u8 {
    return switch (of) {
        .container, .instance => |container| switch (self.kindOf(container) orelse return null) {
            .keyword_struct => "struct",
            .keyword_union => "union",
            .keyword_enum => "enum",
            .keyword_opaque => "opaque",
            else => null,
        },
        .pointer => "pointer",
        .optional => "optional",
        .error_union => "error_union",
        .fn_type, .function => "fn",
        .primitive => |name| primitiveKind(name),
        else => null,
    };
}

/// The `std.builtin.Type` tag a primitive type is of (`u8` an `int`), null where the name is none.
fn primitiveKind(name: []const u8) ?[]const u8 {
    const named = std.StaticStringMap([]const u8).initComptime(.{
        .{ "bool", "bool" },                     .{ "void", "void" },          .{ "type", "type" },
        .{ "noreturn", "noreturn" },             .{ "anyopaque", "opaque" },   .{ "comptime_int", "comptime_int" },
        .{ "comptime_float", "comptime_float" }, .{ "anyerror", "error_set" }, .{ "usize", "int" },
        .{ "isize", "int" },                     .{ "c_char", "int" },         .{ "c_short", "int" },
        .{ "c_ushort", "int" },                  .{ "c_int", "int" },          .{ "c_uint", "int" },
        .{ "c_long", "int" },                    .{ "c_ulong", "int" },        .{ "c_longlong", "int" },
        .{ "c_ulonglong", "int" },               .{ "c_longdouble", "float" }, .{ "f16", "float" },
        .{ "f32", "float" },                     .{ "f64", "float" },          .{ "f80", "float" },
        .{ "f128", "float" },
    });
    if (named.get(name)) |kind| return kind;
    // `u0` to `u65535` and `i0` to `i65535`.
    if (name.len < 2 or (name[0] != 'u' and name[0] != 'i')) return null;
    _ = std.fmt.parseInt(u16, name[1..], 10) catch return null;
    return "int";
}

/// Whether `node` is `@typeInfo(...)`.
fn isTypeInfo(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@typeInfo"),
        else => false,
    };
}

/// What a `null` or an error value among a value's branches or breaks adds to the others:
/// Zig makes them optional, or an error union.
const Peers = struct {
    nullable: bool = false,
    fallible: bool = false,
    tagged: bool = false,

    /// Whether `node` is `null` or an error value, noted as such.
    fn literal(peers: *Peers, tree: *const Ast, node: Ast.Node.Index) bool {
        if (isNull(tree, node)) {
            peers.nullable = true;
            return true;
        }
        if (tree.nodeTag(node) == .error_value) {
            peers.fallible = true;
            return true;
        }
        // An enum literal coerces to its peers' type (`if (c) .no else try f()`, a loop's
        // `else .no`).
        if (tree.nodeTag(node) == .enum_literal) {
            peers.tagged = true;
            return true;
        }
        return false;
    }
};

/// The values chosen as one with what their literals add; enum literals alone are the
/// program's to type, known only as it compiles.
fn peeredChoice(self: *Facts, values: []const Value, peers: Peers) ResolveError!Value {
    if (values.len == 0 and peers.tagged) return .{ .unknown = .comptime_dependent };
    return self.peered(try self.choose(values), peers);
}
fn peered(self: *Facts, chosen: Value, peers: Peers) ResolveError!Value {
    if (chosen == .unknown) return chosen;
    const optional: Value = if (!peers.nullable) chosen else switch (chosen) {
        .optional => chosen,
        // `E!T` and `null`: `E!?T`.
        .error_union => |held| if (held.* == .optional) chosen else .{ .error_union = try self.boxed(.{ .optional = held }) },
        else => .{ .optional = try self.boxed(chosen) },
    };
    if (!peers.fallible or optional == .error_union) return optional;
    return .{ .error_union = try self.boxed(optional) };
}

/// A labeled block: what its `break`s give it, chosen as one, as a `switch`'s branches are.
fn breaks(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.at(file).file.tree;
    const brace = tree.nodeMainToken(node);
    if (brace < 2 or tree.tokenTag(brace - 1) != .colon or tree.tokenTag(brace - 2) != .identifier) return null;
    // Zig refuses a label that shadows another, so the name finds this block's breaks.
    const label = tree.tokenSlice(brace - 2);
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var values: std.ArrayList(Value) = .empty;
    var peers: Peers = .{};
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break") continue;
        const jump: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(jump);
        if (at < first or at > last) continue;
        const data = tree.nodeData(jump).opt_token_and_opt_node;
        const token = data[0].unwrap() orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(token), label)) continue;
        const operand = data[1].unwrap() orelse return null;
        if (never(tree, operand)) continue;
        // A break in a branch this instantiation does not take gives nothing.
        if (try self.dead(file, jump)) continue;
        if (peers.literal(tree, operand)) continue;
        try values.append(self.gpa, try self.resolveIn(env, file, operand));
    }
    return try self.peeredChoice(values.items, peers);
}

/// A loop used as a value (`const e = for (xs) |x| { if (p(x)) break x; } else null;`): what
/// its own breaks give, chosen with its `else` branch as a `switch`'s branches are. A break
/// is the loop's own when it names the loop's label, or names none and no loop nested in this
/// one encloses it.
fn loopValue(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    // `while (true)` ends only by a break: it has no `else` to give a value.
    const body: Ast.Node.Index, const otherwise: ?Ast.Node.Index, const label: ?[]const u8 = if (tree.fullFor(node)) |loop|
        .{ loop.ast.then_expr, loop.ast.else_expr.unwrap() orelse return null, if (loop.label_token) |t| tree.tokenSlice(t) else null }
    else if (tree.fullWhile(node)) |loop|
        .{ loop.ast.then_expr, loop.ast.else_expr.unwrap() orelse if (isTrue(tree, loop.ast.cond_expr)) null else return null, if (loop.label_token) |t| tree.tokenSlice(t) else null }
    else
        return null;
    var values: std.ArrayList(Value) = .empty;
    var peers: Peers = .{};
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break") continue;
        const jump: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(jump);
        if (at < first or at > last) continue;
        const data = tree.nodeData(jump).opt_token_and_opt_node;
        if (data[0].unwrap()) |token| {
            if (label == null or !std.mem.eql(u8, tree.tokenSlice(token), label.?)) continue;
        } else {
            // The innermost loop around the break, short of this one, takes it.
            var up = model.parentOf(jump);
            const inner = while (up) |p| : (up = model.parentOf(p)) {
                if (p == node) break false;
                if (tree.fullFor(p) != null or tree.fullWhile(p) != null) break true;
            } else true;
            if (inner) continue;
        }
        const operand = data[1].unwrap() orelse return null;
        if (never(tree, operand)) continue;
        // A break in a branch this instantiation does not take gives nothing.
        if (try self.dead(file, jump)) continue;
        if (peers.literal(tree, operand)) continue;
        try values.append(self.gpa, try self.resolve(file, operand));
    }
    if (otherwise) |value| if (!peers.literal(tree, value) and !never(tree, value)) try values.append(self.gpa, try self.resolve(file, value));
    if (values.items.len == 0) return null;
    return try self.peeredChoice(values.items, peers);
}

/// A call through a field that holds a function pointer (`read: *const fn (...) R`): what
/// the pointer's function type returns.
fn throughPointer(self: *Facts, file: Project.FileId, callee: Ast.Node.Index) ResolveError!?Value {
    var decl = switch (try self.definition(file, callee)) {
        .decl => |d| d,
        .none => return null,
        .unknown => |why| return .{ .unknown = why },
    };
    var record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    // A local holding the field, unwrapped: `const f = x.handler orelse return;`.
    if (record.kind == .variable) {
        const local = &self.project.at(decl.file).file.tree;
        var value = (local.fullVarDecl(record.node) orelse return null).ast.init_node.unwrap() orelse return null;
        while (true) value = switch (local.nodeTag(value)) {
            .@"orelse" => local.nodeData(value).node_and_node[0],
            .unwrap_optional, .grouped_expression => local.nodeData(value).node_and_token[0],
            else => break,
        };
        decl = switch (try self.definition(decl.file, value)) {
            .decl => |d| d,
            .none => return null,
            .unknown => |why| return .{ .unknown = why },
        };
        record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    }
    if (record.kind != .field) return null;
    const tree = &self.project.at(decl.file).file.tree;
    var declared = (self.project.at(decl.file).model.containerField(tree, record.node) orelse return null).ast.type_expr.unwrap() orelse return null;
    if (tree.nodeTag(declared) == .optional_type) declared = tree.nodeData(declared).node;
    if (tree.fullPtrType(declared)) |ptr| declared = ptr.ast.child_type;
    var buffer: [1]Ast.Node.Index = undefined;
    const signature = tree.fullFnProto(&buffer, declared) orelse return null;
    const result = signature.ast.return_type.unwrap() orelse return null;
    const value = try self.resolve(decl.file, result);
    if (value == .unknown) return null;
    return try self.valueOf(value);
}

/// Whether `node` is `null`, through parentheses: a primitive value no declaration can take.
pub fn isNull(tree: *const Ast, node: Ast.Node.Index) bool {
    const at = ungrouped(tree, node);
    return tree.nodeTag(at) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(at)), "null");
}

fn never(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .unreachable_literal, .@"return", .@"break", .@"continue" => true,
        .grouped_expression => never(tree, tree.nodeData(node).node_and_token[0]),
        // Every branch leaves: an `if` with an `else`, a `switch`.
        .@"if", .if_simple => blk: {
            const branch = tree.fullIf(node).?; // unreachable: the tag is an `if`'s
            break :blk never(tree, branch.ast.then_expr) and never(tree, branch.ast.else_expr.unwrap() orelse break :blk false);
        },
        .@"switch", .switch_comma => for (tree.fullSwitch(node).?.ast.cases) |case| { // unreachable: the tag is a switch's
            if (!never(tree, tree.fullSwitchCase(case).?.ast.target_expr)) break false; // unreachable: a switch's cases are cases
        } else true,
        // A block no `break` names, whose last statement leaves (`{ shared = true; continue; }`).
        .block, .block_semicolon, .block_two, .block_two_semicolon => blk: {
            const brace = tree.nodeMainToken(node);
            if (brace >= 2 and tree.tokenTag(brace - 1) == .colon and tree.tokenTag(brace - 2) == .identifier) break :blk false;
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node) orelse break :blk false;
            break :blk statements.len != 0 and never(tree, statements[statements.len - 1]);
        },
        // `undefined` takes the type of the other branches.
        .identifier => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "undefined"),
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => for ([_][]const u8{ "@compileError", "@panic", "@trap" }) |name| {
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name)) break true;
        } else false,
        else => false,
    };
}

/// What a capture binds, where its source resolves: an `if` or `while` payload is its
/// condition's optional or error-union payload and its error capture an error; a `catch`
/// capture is an error; a switch prong's payload is the field of the subject's union that
/// every item of the prong names, or the subject itself when it is no union; a `for` capture
/// is its input's element, or a number for a range. A `|*x|` capture points at it. Anything
/// else stays unknown: an `else` prong of a union, a prong's tag capture, an input that is not
/// a slice.
fn captured(self: *Facts, env: ?*const Env, decl: Decl) ResolveError!Value {
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    const tree = &self.project.at(decl.file).file.tree;
    const node = record.node;
    const name = record.token;
    const by_pointer = tree.tokenTag(name - 1) == .asterisk;
    const bound: Value = if (tree.fullIf(node)) |branch|
        try self.conditional(env, decl.file, branch.payload_token, branch.error_token, branch.ast.cond_expr, name)
    else if (tree.fullWhile(node)) |loop|
        try self.conditional(env, decl.file, loop.payload_token, loop.error_token, loop.ast.cond_expr, name)
    else if (tree.nodeTag(node) == .@"catch")
        .error_set
    else if (tree.fullSwitchCase(node)) |case|
        try self.switchPayload(env, decl.file, node, case, name)
    else if (tree.fullFor(node)) |loop|
        try self.element(env, decl.file, loop, name)
    else
        .{ .unknown = .unsupported };
    if (bound == .unknown or !by_pointer) return bound;
    // `|*x|`: a pointer to the one item captured.
    return self.pointerTo(bound, .one);
}

fn conditional(self: *Facts, env: ?*const Env, file: Project.FileId, payload_token: ?Ast.TokenIndex, error_token: ?Ast.TokenIndex, condition: Ast.Node.Index, name: Ast.TokenIndex) ResolveError!Value {
    if (error_token) |token| if (token == name) return .error_set;
    const first = payload_token orelse return .{ .unknown = .unsupported };
    if (first != name and first + 1 != name) return .{ .unknown = .unsupported };
    return self.unwrappedCondition(try self.resolveIn(env, file, condition));
}

/// What a condition `value` captures: the payload of an optional or an error union, each of
/// a choice's (`if (@field(v, name)) |part|` over fields of several types).
fn unwrappedCondition(self: *Facts, value: Value) ResolveError!Value {
    return switch (value) {
        .alternatives => |each| blk: {
            const parts = try self.gpa.alloc(Value, each.len);
            for (each, parts) |one, *part| part.* = try self.unwrappedCondition(one);
            break :blk self.choose(parts);
        },
        .optional, .error_union => |inner| inner.*,
        // Zig unwraps only an optional or an error union: a condition read as a payload is one
        // whose wrapper a peer with `null` adds, which this reading keeps no record of (`const
        // a, const b = cut(x) orelse .{ x, null }` makes `b` optional), and captures that payload.
        .pointer, .instance, .array, .scalar => value,
        .unknown => value,
        else => .{ .unknown = .unsupported },
    };
}

fn switchPayload(self: *Facts, env: ?*const Env, file: Project.FileId, case_node: Ast.Node.Index, full: Ast.full.SwitchCase, name: Ast.TokenIndex) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    // The payload is the first capture; a second is the prong's tag.
    const first = full.payload_token orelse return .{ .unknown = .unsupported };
    if (first != name and first + 1 != name) return .{ .unknown = .unsupported };
    const parent = self.project.at(file).model.parentOf(case_node) orelse return .{ .unknown = .unsupported };
    const whole = tree.fullSwitch(parent) orelse return .{ .unknown = .unsupported };
    const subject = try self.resolveIn(env, file, whole.ast.condition);
    // A switch on type information (`@typeInfo(T)`) captures the part its prong names, of
    // each type a choice of them gives.
    if (reflectedInfo(subject)) {
        const each: []const Value = if (subject == .alternatives) subject.alternatives else &.{subject};
        const parts = try self.gpa.alloc(Value, each.len);
        for (each, parts) |one, *part| part.* = if (full.ast.values.len != 1 or tree.nodeTag(full.ast.values[0]) != .enum_literal)
            .{ .reflected = .{ .of = one.reflected.of, .at = .part } }
        else
            try self.reflectedMember(one.reflected, try self.memberName(tree.tokenSlice(tree.nodeMainToken(full.ast.values[0]))));
        return self.choose(parts);
    }
    // A pointer's target resolves as its type: a dereferenced subject is a container here.
    const container = switch (subject) {
        .instance, .container => |c| c,
        .unknown => return subject,
        // A number, a boolean or an error: the capture is the subject's value.
        .scalar, .primitive, .error_set => return subject,
        else => return .{ .unknown = .unsupported },
    };
    if (!self.isUnion(container)) return .{ .instance = container };
    // A union's `else` prong captures the union itself; an `inline else` prong each payload.
    if (full.ast.values.len == 0 and full.inline_token == null) return .{ .instance = container };
    // The fields the prong takes: those its items name, or for `inline else` those no other
    // prong names.
    var fields: std.ArrayList(Decl) = .empty;
    if (full.ast.values.len == 0) {
        const model = &self.project.at(container.file).model;
        const owner = &self.project.at(container.file).file.tree;
        for (model.declarations, 0..) |record, i| {
            if (record.kind != .field or record.scope != container.scope) continue;
            const field_name = try self.memberName(owner.tokenSlice(record.token));
            if (try self.prongNames(file, whole, field_name)) continue;
            try fields.append(self.gpa, .{ .file = container.file, .index = @fromBackingInt(@intCast(i)) });
        }
    } else for (full.ast.values) |item| {
        if (tree.nodeTag(item) != .enum_literal) return .{ .unknown = .unsupported };
        const field = self.member(container, try self.memberName(tree.tokenSlice(tree.nodeMainToken(item)))) orelse return .{ .unknown = .unresolved };
        if (self.project.at(field.file).model.declarations[@backingInt(field.index)].kind != .field) return .{ .unknown = .unsupported };
        try fields.append(self.gpa, field);
    }
    if (fields.items.len == 0) return .{ .unknown = .unsupported };
    const values = try self.gpa.alloc(Value, fields.items.len);
    for (fields.items, values) |field, *value| {
        // Of a union a type function made, read with its call's bindings (`parsed: T`); a tag
        // with no type holds `void`.
        value.* = try self.memberOf(container, field);
        if (value.* == .unknown) return value.*;
    }
    // An `inline` prong is analysed once per field, its capture each one's payload in turn;
    // otherwise Zig requires the payloads to be one type.
    if (full.inline_token != null) return self.choose(values);
    for (values[1..]) |value| if (!same(values[0], value, 0)) return .{ .unknown = .unsupported };
    return values[0];
}

/// Whether a prong of `whole` names the union field `name`.
fn prongNames(self: *Facts, file: Project.FileId, whole: Ast.full.Switch, name: []const u8) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    for (whole.ast.cases) |case| for (tree.fullSwitchCase(case).?.ast.values) |item| {
        if (tree.nodeTag(item) == .enum_literal and std.mem.eql(u8, try self.memberName(tree.tokenSlice(tree.nodeMainToken(item))), name)) return true;
    };
    return false;
}

fn element(self: *Facts, env: ?*const Env, file: Project.FileId, loop: Ast.full.For, name: Ast.TokenIndex) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const position = Model.capturePosition(tree, loop, name) orelse return .{ .unknown = .unsupported };
    if (position >= loop.ast.inputs.len) return .{ .unknown = .unsupported };
    const input = loop.ast.inputs[position];
    if (tree.nodeTag(input) == .for_range) return .scalar;
    return self.forElement(env, file, input, 0);
}

/// An element of what a `for` takes: of an `if`'s branches each (`if (c) list else &.{one}`),
/// of a literal written in place, its elements (an `inline for` over a tuple each in turn, a
/// pointer to one a slice of them), else of the resolved input.
fn forElement(self: *Facts, env: ?*const Env, file: Project.FileId, input: Ast.Node.Index, depth: usize) ResolveError!Value {
    if (depth == 16) return .{ .unknown = .budget };
    const tree = &self.project.at(file).file.tree;
    switch (tree.nodeTag(input)) {
        .grouped_expression => return self.forElement(env, file, tree.nodeData(input).node_and_token[0], depth + 1),
        .address_of => {
            var buffer: [2]Ast.Node.Index = undefined;
            const pointed = tree.nodeData(input).node;
            if (tree.fullArrayInit(&buffer, pointed) != null) return self.forElement(env, file, pointed, depth + 1);
        },
        .@"if", .if_simple => {
            const branch = tree.fullIf(input).?; // unreachable: the tag is an `if`'s
            if (branch.payload_token == null and branch.error_token == null) if (branch.ast.else_expr.unwrap()) |otherwise| {
                var each: std.ArrayList(Value) = .empty;
                for ([_]Ast.Node.Index{ branch.ast.then_expr, otherwise }) |taken| {
                    if (never(tree, taken)) continue;
                    try each.append(self.gpa, try self.forElement(env, file, taken, depth + 1));
                }
                return self.choose(each.items);
            };
        },
        else => {},
    }
    // A tuple or array written in place, of no type of its own: each element in turn.
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullArrayInit(&buffer, input)) |list| if (list.ast.type_expr == .none) {
        const each = try self.gpa.alloc(Value, list.ast.elements.len);
        for (list.ast.elements, each) |item, *out| out.* = try self.resolveIn(env, file, item);
        return self.choose(each);
    };
    // A `for` takes arrays, pointers to arrays and slices, never a single item: a resolved
    // pointer input is a slice, whose element is what it points at. One of a constant table
    // of functions is each it holds.
    const item = try self.indexed(try self.resolveIn(env, file, input), {});
    if (callable(item) and !identified(item)) return self.identity(item, try self.tableElements(file, input));
    return item;
}

fn isUnion(self: *const Facts, container: Container) bool {
    const model = &self.project.at(container.file).model;
    const tree = &self.project.at(container.file).file.tree;
    const scope = model.scopes[@backingInt(container.scope)];
    if (scope.kind != .container) return false;
    return tree.tokenTag(tree.nodeMainToken(scope.node)) == .keyword_union;
}

/// Whether two readings of a container a type function made are one type: the same function
/// bound to the same arguments (`Line(Plain)` and `Line(Guarded)` are two), wherever each call
/// is written, as Zig makes one type per function and comptime arguments. A making whose
/// binding is not read is the same call read with the same bindings.
fn sameMaking(a: ?*const Made, b: ?*const Made, depth: usize) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    if (x == y) return true;
    if (depth >= 64) return false;
    if (x.bound) |bx| if (y.bound) |by| return sameInstantiation(bx, by, depth + 1);
    if (!std.meta.eql(x.function, y.function) or x.file != y.file or x.call != y.call or x.assumed != y.assumed or x.reading != y.reading) return false;
    if (!sameMaking(x.via, y.via, depth + 1)) return false;
    const ex = x.env orelse return y.env == null;
    const ey = y.env orelse return false;
    if (ex == ey) return true;
    if (!std.meta.eql(ex.function, ey.function) or ex.args.len != ey.args.len) return false;
    for (ex.args, ey.args) |one, other| if (!same(one, other, depth + 1)) return false;
    return true;
}

/// Whether two values are one, what they point at compared, not where it is kept, a pointer's
/// size among it.
pub fn sameValue(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .pointer => |inner| inner.size == b.pointer.size and sameValue(inner.child.*, b.pointer.child.*),
        .array => |inner| sameValue(inner.*, b.array.*),
        .optional => |inner| sameValue(inner.*, b.optional.*),
        .error_union => |inner| sameValue(inner.*, b.error_union.*),
        .alternatives => |each| each.len == b.alternatives.len and for (each, b.alternatives) |one, other| {
            if (!sameValue(one, other)) break false;
        } else true,
        .reflected => |r| r.at == b.reflected.at and sameValue(r.of.*, b.reflected.of.*),
        .reified => |r| r.value == b.reified.value and sameValue(r.fields.*, b.reified.fields.*),
        .primitive => |name| std.mem.eql(u8, name, b.primitive),
        // A type a call made is the one another call with the same arguments makes, wherever
        // each is kept (`sameMaking`).
        .container, .instance => |k| switch (b) {
            .container, .instance => |other| k.file == other.file and k.scope == other.scope and sameMaking(k.made_by, other.made_by, 0),
            else => false,
        },
        else => std.meta.eql(a, b),
    };
}

/// The reading `draft` describes, made once: one already made with the same function, outer
/// reading, arguments (`sameValue`), truths and spellings, however many calls deep each chain
/// reaching it is, or a new one. What `resolveIn` keeps by a reading's address is then shared
/// by every call that makes it, and a call of a function in its own reading (`dataField`
/// handing itself `Field.Value`, unknown where `Field` is) is that reading again. A kept
/// reading's depth is the chain that first made it, so a chain of ever new readings still ends
/// (Taint's `readingAt`).
pub fn keptReading(self: *Facts, draft: Env) ResolveError!*const Env {
    const key: ReadingKey = .{ .function = draft.function, .outer = draft.outer };
    const entry = try self.readings.getOrPut(self.gpa, key);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    for (entry.value_ptr.items) |kept| if (sameEnv(kept.*, draft)) return kept;
    const env = try self.gpa.create(Env);
    env.* = draft;
    try entry.value_ptr.append(self.gpa, env);
    return env;
}

const ReadingKey = struct { function: Decl, outer: ?*const Env };

fn sameEnv(a: Env, b: Env) bool {
    if (a.nested != b.nested or a.args.len != b.args.len) return false;
    for (a.args, b.args) |one, other| if (!sameValue(one, other)) return false;
    return sameComptime(a, b);
}

/// Whether two readings bind one function to the same arguments in the same enclosing reading,
/// however many calls deep each is: one instantiation. An unknown argument is never the same.
fn sameInstantiation(a: *const Env, b: *const Env, depth: usize) bool {
    if (a == b) return true;
    if (!std.meta.eql(a.function, b.function) or a.outer != b.outer or a.args.len != b.args.len) return false;
    for (a.args, b.args) |one, other| if (!same(one, other, depth)) return false;
    return sameComptime(a.*, b.*);
}

/// Whether two readings' arguments are the same as conditions and as spelled names and numbers.
fn sameComptime(a: Env, b: Env) bool {
    if (a.truths.len != b.truths.len or a.spelled.len != b.spelled.len or a.values.len != b.values.len) return false;
    for (a.truths, b.truths) |one, other| if (one != other) return false;
    if (!std.mem.eql(bool, a.values, b.values)) return false;
    for (a.spelled, b.spelled) |one, other| {
        if ((one == null) != (other == null)) return false;
        const x = one orelse continue;
        const y = other.?;
        if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
        switch (x) {
            .name => |name| if (!std.mem.eql(u8, name, y.name)) return false,
            .number => |number| if (number != y.number) return false,
        }
    }
    return true;
}

fn same(a: Value, b: Value, depth: usize) bool {
    if (depth == 64) return false;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        // Of one size: `*T` and `[]T` are two types.
        .pointer => |inner| inner.size == b.pointer.size and same(inner.child.*, b.pointer.child.*, depth + 1),
        .array, .optional, .error_union => |inner| switch (b) {
            .array, .optional, .error_union => |other| same(inner.*, other.*, depth + 1),
            else => false,
        },
        .container, .instance => |c| switch (b) {
            .container, .instance => |other| c.file == other.file and c.scope == other.scope and sameMaking(c.made_by, other.made_by, depth + 1),
            else => false,
        },
        .primitive => |p| std.mem.eql(u8, p, b.primitive),
        .function => |f| std.meta.eql(f, b.function),
        .alternatives => |each| each.len == b.alternatives.len and for (each, b.alternatives) |x, y| {
            if (!same(x, y, depth + 1)) break false;
        } else true,
        .unknown => false,
        .error_set, .scalar => true,
        .reflected => false,
        .reified => |built| built.value == b.reified.value and same(built.fields.*, b.reified.fields.*, depth + 1),
        .fn_type => |key| std.meta.eql(key, b.fn_type),
        // One literal is one anonymous type; two literals are two.
        .literal => |l| std.meta.eql(l, b.literal),
    };
}

/// Whether two values are one representation, every field read alike, recursively: what no
/// reader of either can tell apart. A container's making is compared by where it is kept: two
/// makings are two to a reader that reads them, whatever `sameMaking` finds. Past 64 levels,
/// two (the safe side for a choice: both are kept).
fn identical(a: Value, b: Value, depth: usize) bool {
    if (depth == 64) return false;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .unknown => |why| why == b.unknown,
        .primitive => |p| std.mem.eql(u8, p, b.primitive),
        .container, .instance => |c| switch (b) {
            .container, .instance => |other| c.file == other.file and c.scope == other.scope and c.symbolic == other.symbolic and c.made_by == other.made_by,
            else => false,
        },
        .function => |f| std.meta.eql(f, b.function),
        .pointer => |inner| inner.size == b.pointer.size and identical(inner.child.*, b.pointer.child.*, depth + 1),
        .array, .optional, .error_union => |inner| switch (b) {
            .array, .optional, .error_union => |other| identical(inner.*, other.*, depth + 1),
            else => false,
        },
        .error_set, .scalar => true,
        .alternatives => |each| each.len == b.alternatives.len and for (each, b.alternatives) |x, y| {
            if (!identical(x, y, depth + 1)) break false;
        } else true,
        .reflected => |r| r.at == b.reflected.at and identical(r.of.*, b.reflected.of.*, depth + 1),
        .literal => |l| std.meta.eql(l, b.literal),
        .reified => |built| built.value == b.reified.value and identical(built.fields.*, b.reified.fields.*, depth + 1),
        .fn_type => |key| std.meta.eql(key, b.fn_type),
    };
}

/// The container a type function returns when its body ends in one `return` of that container,
/// whatever comptime checks come before. This is the template, not an instantiation: no
/// arguments are evaluated.
pub fn template(self: *Facts, decl: Decl) ResolveError!?Value {
    if (self.templates.get(decl)) |known| return known;
    // A type function that returns another's call is read through it; one that reaches itself
    // again that way makes no container.
    try self.templates.put(self.gpa, decl, null);
    const wide = self.wide;
    const found = try self.findTemplate(decl);
    if (!self.wideSince(wide)) try self.templates.put(self.gpa, decl, found) else _ = self.templates.remove(decl);
    return found;
}
fn findTemplate(self: *Facts, decl: Decl) ResolveError!?Value {
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    const tree = &self.project.at(decl.file).file.tree;
    const lowered = record.lowered orelse return null;
    var fn_node = self.project.at(decl.file).file.zir.?.getDeclaration(lowered).src_node;
    if (tree.nodeTag(fn_node) != .fn_decl) fn_node = self.project.at(decl.file).model.parentOf(fn_node) orelse return null;
    if (tree.nodeTag(fn_node) != .fn_decl) return null;
    const body = tree.nodeData(fn_node).node_and_node[1];
    var body_buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&body_buffer, body) orelse return null;
    if (statements.len == 0 or tree.nodeTag(statements[statements.len - 1]) != .@"return") return null;
    const last = statements[statements.len - 1];
    // Only the final statement may return something else: a `return` before it, in a check, a
    // branch or a nested block, gives this function's own container only by calling it again
    // (`Aligned(T, null)` for a list's natural alignment). Those after it are inside the
    // returned container, where only nested functions can contain one.
    _ = self.recursion(decl, body, last, 0) orelse return null;
    const returned = tree.nodeData(last).opt_node.unwrap() orelse return null;
    // `return if (options.generation) |G| Keyed(T, Tag, G) else Indexed(T, Tag);`: a type function
    // that chooses its container by a comptime option (aegis 0.3's `SlotPool`) makes one of
    // two, each a branch's template. Any other choice makes no template, as before.
    if (tree.fullIf(returned)) |choice| {
        const otherwise = choice.ast.else_expr.unwrap() orelse return null;
        const first = (try self.returnedTemplate(decl, choice.ast.then_expr)) orelse return null;
        const second = (try self.returnedTemplate(decl, otherwise)) orelse return null;
        if (first != .container or second != .container) return null;
        if (first.container.file == second.container.file and first.container.scope == second.container.scope) return first;
        const both = try self.gpa.alloc(Value, 2);
        both[0] = first;
        both[1] = second;
        return .{ .alternatives = both };
    }
    return self.returnedTemplate(decl, returned);
}

/// The template of what a type function's final `return` gives (`findTemplate`): the container
/// it declares, or the one another type function it calls makes.
fn returnedTemplate(self: *Facts, decl: Decl, returned: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.at(decl.file).file.tree;
    var container_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_buffer, returned) == null) {
        // `return Owner(T, false, cleanup);`: the container another type function makes, the
        // same template whatever arguments this one passes it.
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&call_buffer, returned) orelse return null;
        // A callee not known makes a container not known: unknown, never no template.
        const callee = switch (try self.definition(decl.file, call.ast.fn_expr)) {
            .decl => |d| d,
            .none => return .{ .unknown = .unresolved },
            .unknown => |why| return .{ .unknown = why },
        };
        const function = switch (try self.origin(callee)) {
            .decl => |d| d,
            .none => return .{ .unknown = .unresolved },
            .unknown => |why| return .{ .unknown = why },
        };
        if (self.project.at(function.file).model.declarations[@backingInt(function.index)].kind != .function) return null;
        return self.template(function);
    }
    const value = try self.resolve(decl.file, returned);
    return value;
}

pub fn declaration(self: *Facts, decl: Decl) ResolveError!Value {
    const model = &self.project.at(decl.file).model;
    const declaration_record = model.declarations[@backingInt(decl.index)];
    const tree = &self.project.at(decl.file).file.tree;
    if (declaration_record.kind == .function) return .{ .function = decl };
    if (declaration_record.kind == .parameter) {
        if (try self.settledByCalls(decl)) |position| return self.boundByCallers(decl, position);
        const value = try self.resolve(decl.file, declaration_record.node);
        if (value == .primitive and std.mem.eql(u8, value.primitive, "type")) return .{ .unknown = .comptime_dependent };
        const typed = try self.instance(value);
        // A function or a pointer to one: which, each argument its function's every call
        // passes, where every call is the program's.
        if (callable(typed)) if (self.functionOf(decl)) |function| {
            const position = self.parameterPosition(decl.file, function, declaration_record.token) orelse return typed;
            const passed = (try self.callArguments(function, position)) orelse return typed;
            return self.identity(typed, passed);
        };
        return typed;
    }
    if (declaration_record.kind == .capture) return self.captured(null, decl);
    if (declaration_record.kind == .field) {
        const field = model.containerField(tree, declaration_record.node).?; // unreachable: the declaration is a field's
        if (field.ast.type_expr.unwrap()) |t| return self.instance(try self.resolve(decl.file, t));
        // A field with no type: an enum's tag, a value of the enum; a union's, holding `void`;
        // a struct's field always has one.
        const holder: Container = .{ .file = decl.file, .scope = declaration_record.scope };
        return switch (self.kindOf(holder) orelse return .{ .unknown = .unsupported }) {
            .keyword_enum => .{ .instance = holder },
            .keyword_union => .scalar,
            else => .{ .unknown = .unsupported },
        };
    }
    if (tree.fullVarDecl(declaration_record.node)) |variable| {
        const mutable = tree.tokenTag(variable.ast.mut_token) == .keyword_var;
        if (variable.ast.type_node.unwrap()) |t| {
            const type_value = try self.resolve(decl.file, t);
            if (!holdsTypes(type_value)) {
                const typed = try self.instance(type_value);
                // A function or a pointer to one: which, its initializer's and every store's.
                if (!callable(typed)) return typed;
                return self.identity(typed, try self.givenValues(decl));
            }
            // An array of types written element by element where it is declared (std's
            // `Io.Operation.Result`, whose block fills `field_types` through a loop's captures).
            if (type_value == .array and mutable) if (variable.ast.init_node.unwrap()) |init| if (isUndefined(tree, init)) if (model.parentOf(declaration_record.node)) |block|
                return self.writtenElements(null, decl.file, decl.index, block);
        }
        if (variable.ast.init_node.unwrap()) |value| {
            const initial = try self.resolve(decl.file, value);
            if (!mutable) return initial;
            // A `var` that holds types (`comptime var X: type = S;`) is each type it is given,
            // wherever it is read: one declaration, several types over its life.
            const declared_types = if (variable.ast.type_node.unwrap()) |t| holdsTypes(try self.resolve(decl.file, t)) else false;
            if (declared_types or try self.holdsTypeValue(initial, 0) or (variable.ast.type_node == .none and mayBeType(initial) and self.compileTime(decl) and !try self.initIsValue(decl.file, value, 0))) {
                const given = (try self.givenValues(decl)) orelse return .{ .unknown = .unresolved };
                return self.choose(given);
            }
            if (!callable(initial)) return initial;
            return self.identity(initial, try self.givenValues(decl));
        }
        if (model.parentOf(declaration_record.node)) |parent| if (tree.nodeTag(parent) == .assign_destructure) return self.destructured(decl.file, parent, declaration_record.node);
    }
    return .{ .unknown = .unsupported };
}

/// Whether `value` is a type or holds one: a container, a type built from its fields' types,
/// or an aggregate of them.
fn holdsTypeValue(self: *Facts, value: Value, depth: u8) ResolveError!bool {
    if (depth >= 8) return true;
    switch (value) {
        .container => return true,
        .reified => |built| return !built.value,
        // An array, an optional or an error union of types, a pointer to them, or a choice with
        // one.
        .array, .optional, .error_union => |inner| return self.holdsTypeValue(inner.*, depth + 1),
        .pointer => |inner| return self.holdsTypeValue(inner.child.*, depth + 1),
        .alternatives => |each| {
            for (each) |one| if (try self.holdsTypeValue(one, depth + 1)) return true;
            return false;
        },
        // A typeless literal holds types where a part of it may be one (`.{S}`).
        // Type information holds the types it describes (`info.pointer.child`).
        .reflected => return true,
        .literal => |key| {
            const tree = &self.project.at(key.file).file.tree;
            var buffer: [2]Ast.Node.Index = undefined;
            const parts: []const Ast.Node.Index = if (tree.fullArrayInit(&buffer, key.node)) |init| init.ast.elements else if (tree.fullStructInit(&buffer, key.node)) |init| init.ast.fields else return true;
            for (parts) |part| {
                const held = try self.resolve(key.file, part);
                if (try self.holdsTypeValue(held, depth + 1)) return true;
                if (mayBeType(held) and !try self.initIsValue(key.file, part, 0)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Whether `value` may be read as a type as well as a value of one: a primitive, a pointer, an
/// array, an optional, an error union or a function type, which an unannotated `var` may hold
/// as a type (`var X = []const u8;` in a type function Zig runs at compile time, with no
/// `comptime` of its own). `initIsValue` tells a value apart.
fn mayBeType(value: Value) bool {
    return switch (value) {
        .primitive, .pointer, .array, .optional, .error_union, .fn_type => true,
        else => false,
    };
}

/// Whether a `var` is one Zig evaluates at compile time, where alone it may hold a type
/// ("variable of type 'type' must be const or comptime"): declared `comptime var`, in a
/// `comptime` scope, or in a function whose result is `type`. A function called only at
/// compile time with none of these is not read so: the value model does not yet tell a pointer
/// or array type from a value of one, which reading it would need.
fn compileTime(self: *Facts, decl: Decl) bool {
    const source = self.project.at(decl.file);
    const tree = &source.file.tree;
    const record = source.model.declarations[@backingInt(decl.index)];
    if (record.token >= 2 and tree.tokenTag(record.token - 2) == .keyword_comptime) return true;
    var at: ?Model.Scope.Id = record.scope;
    while (at) |id| : (at = source.model.scopes[@backingInt(id)].parent) {
        const scope = source.model.scopes[@backingInt(id)];
        switch (scope.kind) {
            .@"comptime" => return true,
            .function => {
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, scope.node) orelse return false;
                const result = proto.ast.return_type.unwrap() orelse return false;
                return namesType(tree, result);
            },
            else => {},
        }
    }
    return false;
}

/// Whether a `var`'s initializer is a value, never a type, by what it is written as: an
/// address or a slice; an element, a dereference or an unwrap of a value (`try`, `catch` and
/// `orelse` of one); a number or string literal; an initializer written with a type that holds
/// no types; a builtin whose result is a value by its own kind; a call whose result type is
/// known and holds no types; or a name of a declaration whose declared type is so (a const by
/// its own initializer). False where it may be a type: the caller then reads every value the
/// var is given.
fn initIsValue(self: *Facts, file: Project.FileId, node: Ast.Node.Index, depth: u8) ResolveError!bool {
    if (depth >= 8) return false;
    const tree = &self.project.at(file).file.tree;
    const at = ungrouped(tree, node);
    // An address or a slice points into memory: what it points at is read through its owner.
    if (tree.fullSlice(at) != null) return true;
    // An initializer is a value where the type it is written with holds no types; one with
    // none (`.{S}`) may hold types.
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullArrayInit(&buffer, at)) |init| return knownValueType(try self.resolve(file, init.ast.type_expr.unwrap() orelse return false));
    if (tree.fullStructInit(&buffer, at)) |init| return knownValueType(try self.resolve(file, init.ast.type_expr.unwrap() orelse return false));
    switch (tree.nodeTag(at)) {
        .address_of, .string_literal, .multiline_string_literal, .number_literal, .char_literal => return true,
        // An element, a pointee or a payload is a value where what holds it is.
        .array_access => return self.initIsValue(file, tree.nodeData(at).node_and_node[0], depth + 1),
        .deref => return self.initIsValue(file, tree.nodeData(at).node, depth + 1),
        .unwrap_optional => return self.initIsValue(file, tree.nodeData(at).node_and_token[0], depth + 1),
        // What an error union or an optional holds: a value where the operand is one.
        .@"try" => return self.initIsValue(file, tree.nodeData(at).node, depth + 1),
        .@"catch", .@"orelse" => return self.initIsValue(file, tree.nodeData(at).node_and_node[0], depth + 1),
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            // The builtins whose result is a value by their own kind, whatever they are given;
            // any other (`@as(type, T)`, `@call`, `@field`, one Zig adds later) may give a type.
            const values = [_][]const u8{ "@addWithOverflow", "@addrSpaceCast", "@alignCast", "@alignOf", "@atomicLoad", "@atomicRmw", "@bitCast", "@bitOffsetOf", "@intFromBool", "@bitSizeOf", "@mulAdd", "@byteSwap", "@bitReverse", "@offsetOf", "@clz", "@cmpxchgStrong", "@cmpxchgWeak", "@constCast", "@ctz", "@cVaArg", "@divExact", "@divFloor", "@divCeil", "@divTrunc", "@embedFile", "@intFromEnum", "@errorName", "@errorReturnTrace", "@intFromError", "@errorCast", "@extern", "@fieldParentPtr", "@floatCast", "@intFromFloat", "@frameAddress", "@hasDecl", "@hasField", "@inComptime", "@intCast", "@backingInt", "@fromBackingInt", "@enumFromInt", "@errorFromInt", "@floatFromInt", "@ptrFromInt", "@max", "@min", "@mod", "@mulWithOverflow", "@popCount", "@ptrCast", "@intFromPtr", "@rem", "@returnAddress", "@select", "@shlExact", "@shlWithOverflow", "@shrExact", "@shuffle", "@sizeOf", "@splat", "@reduce", "@src", "@sqrt", "@sin", "@cos", "@tan", "@exp", "@log", "@abs", "@floor", "@ceil", "@trunc", "@round", "@subWithOverflow", "@tagName", "@truncate", "@typeInfo", "@typeName", "@unionInit", "@volatileCast" };
            const name = tree.tokenSlice(tree.nodeMainToken(at));
            // By kind, and where what it gives holds no types (`@typeInfo(T)` holds T's parts).
            for (values) |one| if (std.mem.eql(u8, one, name)) return !try self.holdsTypeValue(try self.resolve(file, at), 0);
            // `@as(T, v)` is a value of `T`: one where `T` holds no types.
            if (std.mem.eql(u8, name, "@as")) {
                var args_buffer: [2]Ast.Node.Index = undefined;
                const args = builtinArgs(tree, at, &args_buffer);
                return args.len == 2 and knownValueType(try self.resolve(file, args[0]));
            }
            return false;
        },
        .identifier, .field_access => {},
        else => {
            var call_buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&call_buffer, at) orelse return false;
            const proto = self.prototype(try self.resolve(file, call.ast.fn_expr)) orelse return false;
            return knownValueType(try self.resultOf(proto));
        },
    }
    const decl = switch (try self.definition(file, at)) {
        .decl => |d| d,
        .none, .unknown => return false,
    };
    const source = self.project.at(decl.file);
    const record = source.model.declarations[@backingInt(decl.index)];
    switch (record.kind) {
        .function => return true,
        .parameter => return knownValueType(try self.resolve(decl.file, self.parameterTypeNode(decl) orelse return false)),
        .field => {
            const field = source.model.containerField(&source.file.tree, record.node) orelse return false;
            return knownValueType(try self.resolve(decl.file, field.ast.type_expr.unwrap() orelse return false));
        },
        .variable => {
            const variable = source.file.tree.fullVarDecl(record.node) orelse return false;
            if (variable.ast.type_node.unwrap()) |t| return knownValueType(try self.resolve(decl.file, t));
            return self.initIsValue(decl.file, constInit(&source.file.tree, record) orelse return false, depth + 1);
        },
        .capture => return false,
    }
}

/// Whether a type is known and holds no types as values: what a value of it never is, a type.
fn knownValueType(value: Value) bool {
    return value != .unknown and value != .alternatives and !holdsTypes(value);
}

/// Whether `value` is a function or a pointer to one, by its identity or its type: what a call
/// through it calls is a function's identity, which every source of the value gives.
fn callable(value: Value) bool {
    return switch (value) {
        .function, .fn_type => true,
        .pointer => |inner| callable(inner.child.*),
        .optional => |inner| callable(inner.*),
        .alternatives => |each| for (each) |one| {
            if (!callable(one)) break false;
        } else true,
        else => false,
    };
}

/// Whether `value` and `typed` are the same container, or the same through as many pointers of
/// the same sizes, whatever made each.
fn sameContainer(value: Value, typed: Value) bool {
    return switch (value) {
        .container, .instance => |k| switch (typed) {
            .container, .instance => |other| k.file == other.file and k.scope == other.scope,
            else => false,
        },
        .pointer => |inner| typed == .pointer and inner.size == typed.pointer.size and sameContainer(inner.child.*, typed.pointer.child.*),
        else => false,
    };
}

/// Whether `value` may name a function: one, through a pointer, an optional or an error union,
/// or among a choice.
fn namesFunction(value: Value) bool {
    return switch (value) {
        .function => true,
        .pointer => |inner| namesFunction(inner.child.*),
        .optional, .error_union => |inner| namesFunction(inner.*),
        .alternatives => |each| for (each) |one| {
            if (namesFunction(one)) break true;
        } else false,
        else => false,
    };
}

/// Whether `value` names each function it may be: a function, a pointer to one, a choice of
/// them, never a function type alone.
fn identified(value: Value) bool {
    return switch (value) {
        .function => true,
        .pointer => |inner| identified(inner.child.*),
        .alternatives => |each| for (each) |one| {
            if (!identified(one)) break false;
        } else true,
        else => false,
    };
}

/// A callable value of type `typed` read by its sources: the choice of the functions they
/// give, an optional's `null` giving none, where each source names its functions; else
/// `typed`, which names none, so a call through it may call any.
fn identity(self: *Facts, typed: Value, passed: ?[]const Value) ResolveError!Value {
    const each = passed orelse return self.erased(typed);
    const optional = typed == .optional;
    const pointer = (if (optional) typed.optional.* else typed) == .pointer;
    var named: std.ArrayList(Value) = .empty;
    for (each) |source| {
        const parts: []const Value = if (source == .alternatives) source.alternatives else &.{source};
        for (parts) |part| {
            var one = if (optional and part == .optional) part.optional.* else part;
            // `null`, which no call reaches.
            if (optional and one == .scalar) continue;
            if (!identified(one)) return self.erased(typed);
            // A function given where a pointer to one is held coerces to its address.
            if (pointer and one == .function) {
                // `*const fn`: a pointer to the one function.
                one = try self.pointerTo(one, .one);
            }
            try named.append(self.gpa, one);
        }
    }
    if (named.items.len == 0) return self.erased(typed);
    const chosen = try self.choose(named.items);
    return if (optional) .{ .optional = try self.boxed(chosen) } else chosen;
}

/// A callable value's type alone, naming no function: a function's is its prototype's.
fn erased(self: *Facts, value: Value) ResolveError!Value {
    return switch (value) {
        .function => |decl| blk: {
            const tree = self.syntaxOf(decl.file);
            const node = self.project.at(decl.file).model.declarations[@backingInt(decl.index)].node;
            break :blk .{ .fn_type = .{ .file = decl.file, .node = if (tree.nodeTag(node) == .fn_decl) tree.nodeData(node).node_and_node[0] else node } };
        },
        .pointer => |inner| try self.pointerTo(try self.erased(inner.child.*), inner.size),
        .optional => |inner| .{ .optional = try self.boxed(try self.erased(inner.*)) },
        .alternatives => |each| blk: {
            const mapped = try self.gpa.alloc(Value, each.len);
            for (each, mapped) |one, *out| out.* = try self.erased(one);
            break :blk self.choose(mapped);
        },
        else => value,
    };
}

/// The values an element of the constant table `node` names may be: each element of the array
/// literal its chain of constants ends at. Null where it ends at none.
fn tableElements(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?[]const Value {
    const literal = self.constantLiteral(file, node, 0) orelse return null;
    const tree = self.syntaxOf(literal.file);
    var buffer: [2]Ast.Node.Index = undefined;
    const array = tree.fullArrayInit(&buffer, literal.node) orelse return null;
    const each = try self.gpa.alloc(Value, array.ast.elements.len);
    for (array.ast.elements, each) |item, *out| out.* = try self.resolve(literal.file, try self.throughCasts(literal.file, item));
    return each;
}

/// The expression a constant's chain of names ends at: `node` itself where it names none.
fn constantLiteral(self: *const Facts, file: Project.FileId, node: Ast.Node.Index, depth: u8) ?Key {
    if (depth > 8) return null;
    const tree = self.syntaxOf(file);
    const model = &self.project.at(file).model;
    var at = node;
    while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
    if (tree.nodeTag(at) != .identifier) return .{ .file = file, .node = at };
    const d = (model.reference(at) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(d)];
    if (record.kind != .variable) return null;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) == .keyword_var) return null;
    return self.constantLiteral(file, variable.ast.init_node.unwrap() orelse return null, depth + 1);
}

/// The values a variable is given: its initializer's, and a mutable one's every store, read in
/// its own file. Null where one may go unseen: a public variable, which code this run does not
/// read may write; a store through its address, unless the address is only dropped
/// (`_ = &f`); one of a part, or an update.
fn givenValues(self: *Facts, decl: Decl) ResolveError!?[]const Value {
    var found: std.ArrayList(Value) = .empty;
    for ((try self.givenTo(decl, false)) orelse return null) |given| {
        // `undefined` gives no function a call may reach: calling it is illegal.
        if (isUndefined(self.syntaxOf(given.file), given.node)) continue;
        try found.append(self.gpa, try self.resolve(given.file, try self.throughCasts(given.file, given.node)));
    }
    return found.items;
}

/// The expressions that give a variable its values: its first value, and for a `var`, each
/// store of a whole value over it by its own name (`accesses`); with `parts`, each store to a
/// part of it too, what it then holds, and an `op=` none (what it makes is in the memory the
/// value before points into). Null where a store may give it any: one to a part of it but with
/// `parts`, one that reads it first (`op=`) but with `parts`, memory a builtin or code the
/// program does not hold writes, its address taken (but dropped, `_ = &x`), a store with no
/// one value, one that reaches it by no name of its own, a public `var` another file may
/// write, one whose file's writes are being read. A local `var`'s whole values are read by its
/// mentions (`accesses.givenByName`), a global's and parts from its file's walk. Read once per
/// declaration and `parts`: a flow's rounds ask it of the same names each round.
pub fn givenTo(self: *Facts, decl: Decl, parts: bool) ResolveError!?[]const Key {
    const kept_by = try self.memo(Given);
    if (kept_by.found.get(.{ decl, parts })) |kept| return kept;
    var lasting = true;
    const wide = self.wide;
    const met = self.open_met;
    const found = try self.givenFrom(decl, parts, &lasting);
    // Kept as `resolve` keeps a value: read with budget left, on no answer wider than the built
    // analysis gives (`wideSince`), meeting no query in progress (`open_met`: the calls and
    // loops `handedWith` and `loopedWith` resolve answer provisionally inside one), and not
    // while its file's writes are read.
    if (lasting and self.remaining != 0 and !self.wideSince(wide) and self.open_met == met) try kept_by.found.put(self.gpa, .{ decl, parts }, found);
    return found;
}

const Given = struct { found: std.AutoHashMapUnmanaged(struct { Decl, bool }, ?[]const Key) = .empty };

/// `givenTo`'s answer, read anew; `lasting` false where it holds only for now.
fn givenFrom(self: *Facts, decl: Decl, parts: bool, lasting: *bool) ResolveError!?[]const Key {
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    const variable = self.syntaxOf(decl.file).fullVarDecl(record.node) orelse return null;
    // A local `var` is written only by its name and the pointers its address gives; whole
    // values alone are read by its mentions, with no walk of its file.
    if (!parts and !accesses.global(self, decl) and self.syntaxOf(decl.file).tokenTag(variable.ast.mut_token) == .keyword_var) return accesses.givenByName(self, decl);
    var found: std.ArrayList(Key) = .empty;
    if (variable.ast.init_node.unwrap()) |init| try found.append(self.gpa, .{ .file = decl.file, .node = init });
    if (self.syntaxOf(decl.file).tokenTag(variable.ast.mut_token) != .keyword_var) return found.items;
    if (record.public) return null;
    // Read while its file's writes are (a store's callee, an `extern`'s shape): its stores are
    // not all known yet.
    if (try accesses.walking(self, decl.file)) {
        lasting.* = false;
        return null;
    }
    const in_file = [_]Project.FileId{decl.file};
    var found_sites = accesses.writes(self, .{ .declaration = decl }, &in_file);
    while (try found_sites.next()) |site| {
        if (site.reach != .exact or (site.part and !parts)) return null;
        switch (site.kind) {
            .init, .read => continue,
            .set => {},
            .address => if (self.dropped(site)) continue else if (parts) {
                // A call that takes its address stores through it what it is given; a loop's
                // pointer capture of it, what its body stores through the capture.
                try found.appendSlice(self.gpa, (try self.loopedWith(site) orelse try self.handedWith(site)) orelse return null);
                continue;
            } else return null,
            .update => if (parts) continue else return null,
            .covered, .open => return null,
        }
        try found.append(self.gpa, .{ .file = site.file, .node = site.value orelse return null });
    }
    return found.items;
}

/// What a `for` loop given a place's address as an input (`for (&out.each) |*slot|`) stores
/// through it: nothing where its capture takes elements by value or none takes them; each value
/// its body stores through a pointer capture (`slot.* = v`, `slot.f = v`), found by the
/// capture's every mention (`accesses.reads`). Null where the capture may go elsewhere: given
/// as a value, its place's address taken, a method's receiver, a mention not read exactly. Not
/// a loop's input: none of this (`.none`), for `handedWith`.
fn loopedWith(self: *Facts, site: accesses.Site) ResolveError!?(?[]const Key) {
    const tree = self.syntaxOf(site.file);
    const model = &self.project.at(site.file).model;
    if (tree.nodeTag(site.node) != .address_of) return null;
    const parent = model.parentOf(site.node) orelse return null;
    const loop = tree.fullFor(parent) orelse return null;
    const position = std.mem.findScalar(Ast.Node.Index, loop.ast.inputs, site.node) orelse return null;
    const capture = for (model.declarations, 0..) |d, i| {
        if (d.kind == .capture and d.node == parent and Model.capturePosition(tree, loop, d.token) == position) break i;
    } else return @as(?[]const Key, &.{});
    const record = model.declarations[capture];
    if (tree.tokenTag(record.token - 1) != .asterisk) return @as(?[]const Key, &.{});
    var out: std.ArrayList(Key) = .empty;
    const in_file = [_]Project.FileId{site.file};
    var mentions = accesses.reads(self, .{ .declaration = .{ .file = site.file, .index = @fromBackingInt(@intCast(capture)) } }, &in_file);
    while (try mentions.next()) |mention| {
        if (mention.reach != .exact) return @as(?[]const Key, null);
        // The place the mention leads to through members, elements, payloads and `.*`.
        var top = mention.node;
        while (model.parentOf(top)) |above| : (top = above) switch (tree.nodeTag(above)) {
            .deref, .unwrap_optional, .grouped_expression => {},
            .field_access => if (tree.nodeData(above).node_and_token[0] != top) break,
            .array_access => if (tree.nodeData(above).node_and_node[0] != top) break,
            else => break,
        };
        if (top == mention.node) return @as(?[]const Key, null);
        const use = model.parentOf(top) orelse return @as(?[]const Key, null);
        switch (tree.nodeTag(use)) {
            .assign => {
                const target, const value = tree.nodeData(use).node_and_node;
                if (target == top) try out.append(self.gpa, .{ .file = site.file, .node = value });
            },
            // Its address, a slice of it, a destructure's target: written past what is read here.
            .address_of, .slice_open, .slice, .slice_sentinel, .assign_destructure => return @as(?[]const Key, null),
            .call_one, .call_one_comma, .call, .call_comma => {
                // A method of the element's: its receiver may be its address.
                var buffer: [1]Ast.Node.Index = undefined;
                if (tree.fullCall(&buffer, use).?.ast.fn_expr == top) return @as(?[]const Key, null); // unreachable: the tag is a call's
            },
            else => {
                // A capture of it by its address (`if (slot.*) |*p|`) writes it where that goes.
                if (tree.fullFor(use)) |inner| if (std.mem.findScalar(Ast.Node.Index, inner.ast.inputs, top) != null) return @as(?[]const Key, null);
                if (tree.fullIf(use)) |inner| if (inner.ast.cond_expr == top and inner.payload_token != null and tree.tokenTag(inner.payload_token.?) == .asterisk) return @as(?[]const Key, null);
                if (tree.fullWhile(use)) |inner| if (inner.ast.cond_expr == top and inner.payload_token != null and tree.tokenTag(inner.payload_token.?) == .asterisk) return @as(?[]const Key, null);
                if (tree.fullSwitch(use)) |inner| if (inner.ast.condition == top) for (inner.ast.cases) |case| {
                    const named = tree.fullSwitchCase(case).?.payload_token orelse continue; // unreachable: a switch's case
                    if (tree.tokenTag(named) == .asterisk) return @as(?[]const Key, null);
                };
            },
        }
    }
    return @as(?[]const Key, out.items);
}

/// What a call that takes a place's address may store through it, as far as the addresses it
/// holds go: each other argument some callee may store there what it holds (`storesAddress`),
/// where no callee may store there an address of the place's own memory:
/// `out.breaks.setUnion(paths.breaks)` gives `out` what `paths.breaks` holds. Null for an
/// address taken other than as a call's receiver or argument, or a callee that may store one or
/// does not resolve.
fn handedWith(self: *Facts, site: accesses.Site) ResolveError!?[]const Key {
    const tree = self.syntaxOf(site.file);
    const model = &self.project.at(site.file).model;
    // The address: the receiver a method's call takes, or `&x` given as an argument.
    const call_node: Ast.Node.Index, const given: Ast.Node.Index = if (tree.nodeTag(site.node) == .address_of)
        .{ model.parentOf(site.node) orelse return null, site.node }
    else
        .{ site.node, site.target orelse return null };
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&buffer, call_node) == null) return null;
    const call = (try calls.at(self, site.file, call_node)) orelse return null;
    const args = switch (call.args) {
        .known => |each| each,
        .unknown => return null,
    };
    const position = std.mem.findScalar(Ast.Node.Index, args, given) orelse return null;
    const functions: []const Decl = switch (call.callee) {
        .function => |function| &.{function},
        .choice => |each| each,
        .any => return null,
    };
    for (functions) |function| if ((try self.storesAddress(function, position, position)) != false) return null;
    var out: std.ArrayList(Key) = .empty;
    for (args, 0..) |arg, k| {
        if (k == position) continue;
        var stored: ?bool = false;
        for (functions) |function| stored = anyOf(stored, try self.storesAddress(function, position, k));
        if (stored != false) try out.append(self.gpa, .{ .file = site.file, .node = arg });
    }
    return out.items;
}

const OwnStores = struct {
    found: std.AutoHashMapUnmanaged(Reading.Key, Reading) = .empty,
    /// The readings in progress, outermost first.
    stack: std.ArrayList(Reading.Key) = .empty,
    /// The readings kept while one in progress was assumed none, innermost assumption last.
    provisional: std.ArrayList(Reading.Key) = .empty,
    /// The outermost reading in progress the current one met, assumed none there.
    low: usize = std.math.maxInt(usize),

    const Reading = union(enum) {
        reading: usize,
        read: ?bool,

        /// The function, what is read (a store through a parameter, or its result), the
        /// parameter whose value is followed.
        const Key = struct { Decl, Into, usize };
    };

    /// Where a value goes: memory a parameter points at, or the function's result, read
    /// `reaching` or not (`Own.reaching`).
    const Into = union(enum) {
        param: usize,
        result: bool,
    };
};

/// Whether `function` may store, into the memory its parameter at `into` points at, a value
/// that is or holds what its parameter at `from` holds. With `from` being `into`: an address of
/// that memory itself (`self.next = self`, `self.view = &self.buf`, or a callee it hands that
/// address to doing so), what makes a value of it point into itself; a store into memory the
/// parameter's pointers reach (`self.items[i] = v`) writes none of its own, and an address read
/// out of memory (`self.next`) is none but where such a store put it. With another `from`: the
/// parameter's value, or anything read through it (`into.next = from.next`), which the caller
/// may have put there. Null where it cannot tell: a target or a value it does not follow, a
/// copy of memory into it, a callee that does not resolve, a function with no body.
///
/// Recursion reads as the least answer: a reading met again while in progress is assumed none,
/// what a store in some finite run of calls makes. Where the outermost reading so assumed comes
/// out none the assumption held and each reading kept under it stands; otherwise those are
/// dropped and read again.
pub fn storesAddress(self: *Facts, function: Decl, into: usize, from: usize) ResolveError!?bool {
    return self.ownReading(function, .{ .param = into }, from);
}

/// Whether `function`'s result may be or hold what its parameter at `from` holds: an address
/// into the memory it points at (`&self.buf`, `self` itself), or, `reaching`, anything read
/// through it too. A value read out of that memory not `reaching` (`self.items`) is none but
/// where a store put one there, as `storesAddress` reads it.
pub fn returnsAddress(self: *Facts, function: Decl, from: usize, reaching: bool) ResolveError!?bool {
    return self.ownReading(function, .{ .result = reaching }, from);
}

fn ownReading(self: *Facts, function: Decl, into: OwnStores.Into, from: usize) ResolveError!?bool {
    const own_stores = try self.memo(OwnStores);
    const key: OwnStores.Reading.Key = .{ function, into, from };
    if (own_stores.found.get(key)) |entry| switch (entry) {
        .read => |kept| return kept,
        .reading => |depth| {
            own_stores.low = @min(own_stores.low, depth);
            return false;
        },
    };
    const depth = own_stores.stack.items.len;
    try own_stores.stack.append(self.gpa, key);
    try own_stores.found.put(self.gpa, key, .{ .reading = depth });
    const outer_low = own_stores.low;
    own_stores.low = std.math.maxInt(usize);
    const kept_before = own_stores.provisional.items.len;
    const found = try self.findOwnStores(function, into, from);
    _ = own_stores.stack.pop();
    const low = own_stores.low;
    own_stores.low = @min(outer_low, low);
    try own_stores.found.put(self.gpa, key, .{ .read = found });
    if (low < depth) {
        // Read under an assumption about one further out: it stands or falls with that one.
        try own_stores.provisional.append(self.gpa, key);
    } else if (own_stores.provisional.items.len > kept_before) {
        // Its own assumption: held where it comes out none.
        if (found != false) for (own_stores.provisional.items[kept_before..]) |undone| {
            _ = own_stores.found.remove(undone);
        };
        own_stores.provisional.shrinkRetainingCapacity(kept_before);
    }
    return found;
}

/// What may be so of each of several: so where one is, unknown where one may be.
fn anyOf(a: ?bool, b: ?bool) ?bool {
    if (a == true or b == true) return true;
    if (a == null or b == null) return null;
    return false;
}

/// Where both may be so: a store into the memory with an address of it.
fn bothOf(a: ?bool, b: ?bool) ?bool {
    if (a == false or b == false) return false;
    if (a == true and b == true) return true;
    return null;
}

fn findOwnStores(self: *Facts, function: Decl, into: OwnStores.Into, from: usize) ResolveError!?bool {
    const tree = self.syntaxOf(function.file);
    const whole = self.scopeNode(function);
    if (tree.nodeTag(whole) != .fn_decl) return null;
    const body = tree.nodeData(whole).node_and_node[1];
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    const reaching = switch (into) {
        .param => |at| from != at,
        .result => |all| all,
    };
    const own: Own = .{ .facts = self, .function = function, .whole = whole, .position = switch (into) {
        .param => |at| at,
        .result => from,
    } };
    const given: Own = .{ .facts = self, .function = function, .whole = whole, .position = from, .reaching = reaching };
    var out: ?bool = false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        if (into == .result) {
            if (tag != .@"return" or !self.ownStatement(function.file, whole, body, node)) continue;
            out = anyOf(out, try given.address(tree.nodeData(node).opt_node.unwrap() orelse continue, 0));
            if (out == true) return true;
            continue;
        }
        const found: ?bool = switch (tag) {
            .assign => found: {
                if (!self.ownStatement(function.file, whole, body, node)) continue;
                const target, const value = tree.nodeData(node).node_and_node;
                break :found bothOf(try own.place(target, 0), try given.address(value, 0));
            },
            .assign_destructure => found: {
                if (!self.ownStatement(function.file, whole, body, node)) continue;
                const whole_value = tree.assignDestructure(node);
                var stored: ?bool = false;
                for (whole_value.ast.variables) |target| {
                    if (tree.fullVarDecl(target) == null) stored = anyOf(stored, try own.place(target, 0));
                }
                break :found bothOf(stored, try given.address(whole_value.ast.value_expr, 0));
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => found: {
                if (!self.ownStatement(function.file, whole, body, node)) continue;
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                var buffer: [2]Ast.Node.Index = undefined;
                const args = builtinArgs(tree, node, &buffer);
                for (accesses.writer_builtins) |entry| {
                    if (!std.mem.eql(u8, name, entry[0])) continue;
                    if (entry[1].pointer >= args.len) break :found null;
                    const target = try own.address(args[entry[1].pointer], 0);
                    // A copy writes what the source memory holds, which is not followed.
                    const value: ?bool = if (entry[1].value) |k| (if (k < args.len) try given.address(args[k], 0) else null) else null;
                    break :found bothOf(target, value);
                }
                continue;
            },
            .call_one, .call_one_comma, .call, .call_comma => found: {
                if (!self.ownStatement(function.file, whole, body, node)) continue;
                break :found try own.handed(given, node);
            },
            .asm_simple, .@"asm" => if (self.ownStatement(function.file, whole, body, node)) null else continue,
            else => continue,
        };
        out = anyOf(out, found);
        if (out == true) return true;
    }
    return out;
}

/// Whether an expression in `function` may be or hold an address into the memory its parameter
/// at `position` points at, or names a place in it; `reaching`, or anything read through it.
const Own = struct {
    facts: *Facts,
    function: Decl,
    whole: Ast.Node.Index,
    position: usize,
    /// What memory the parameter reaches holds counts too: memory not the stored one, which the
    /// caller may have filled with any address.
    reaching: bool = false,

    const depth_limit = 16;

    fn syntax(o: Own) *const Ast {
        return o.facts.syntaxOf(o.function.file);
    }

    fn lexicon(o: Own) *const Model {
        return &o.facts.project.at(o.function.file).model;
    }

    /// Whether the place `node` names is in that memory: past the first pointer its path goes
    /// through, by where that pointer points.
    fn place(o: Own, node: Ast.Node.Index, depth: u8) ResolveError!?bool {
        if (depth >= depth_limit) return null;
        const tree = o.syntax();
        switch (tree.nodeTag(node)) {
            .grouped_expression, .unwrap_optional => return o.place(tree.nodeData(node).node_and_token[0], depth + 1),
            .deref => return o.address(tree.nodeData(node).node, depth + 1),
            .field_access, .array_access => {
                const holder = if (tree.nodeTag(node) == .array_access) tree.nodeData(node).node_and_node[0] else tree.nodeData(node).node_and_token[0];
                if (accesses.pointing(try o.facts.resolve(o.function.file, holder))) return o.address(holder, depth + 1);
                return o.place(holder, depth + 1);
            },
            // A name: memory of the function's own, or a copy it holds.
            .identifier => return false,
            else => return null,
        }
    }

    /// Whether the value `node` gives may be or hold such an address.
    fn address(o: Own, node: Ast.Node.Index, depth: u8) ResolveError!?bool {
        if (depth >= depth_limit) return null;
        const tree = o.syntax();
        const model = o.lexicon();
        const at = try o.facts.throughCasts(o.function.file, node);
        // A value of a type that holds no address (a number, an enum's tag) holds none, whatever
        // gives it.
        if (try o.facts.holdsNoAddress(try o.facts.resolve(o.function.file, at))) return false;
        switch (tree.nodeTag(at)) {
            .number_literal, .char_literal, .string_literal, .multiline_string_literal, .enum_literal, .error_value => return false,
            .@"try", .@"comptime", .@"nosuspend" => return o.address(tree.nodeData(at).node, depth + 1),
            .grouped_expression => return o.address(tree.nodeData(at).node_and_token[0], depth + 1),
            .address_of => return o.place(tree.nodeData(at).node, depth + 1),
            .slice_open, .slice, .slice_sentinel => {
                const base = tree.fullSlice(at).?.ast.sliced; // unreachable: the tag is a slice's
                if (accesses.pointing(try o.facts.resolve(o.function.file, base))) return o.address(base, depth + 1);
                return o.place(base, depth + 1);
            },
            // A value read out of memory: through a pointer, what a store put there; of a value
            // held by name, what that value holds.
            .field_access, .array_access, .unwrap_optional => {
                const holder = switch (tree.nodeTag(at)) {
                    .array_access => tree.nodeData(at).node_and_node[0],
                    else => tree.nodeData(at).node_and_token[0],
                };
                if (!o.reaching and accesses.pointing(try o.facts.resolve(o.function.file, holder))) return false;
                return o.address(holder, depth + 1);
            },
            .deref => return if (o.reaching) o.address(tree.nodeData(at).node, depth + 1) else false,
            .@"orelse", .@"catch", .bool_and, .bool_or, .add, .sub, .add_wrap, .sub_wrap => {
                const lhs, const rhs = tree.nodeData(at).node_and_node;
                return anyOf(try o.address(lhs, depth + 1), try o.address(rhs, depth + 1));
            },
            .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .bool_not => return false,
            .identifier => {
                const text = tree.tokenSlice(tree.nodeMainToken(at));
                for ([_][]const u8{ "undefined", "null", "true", "false" }) |word| if (std.mem.eql(u8, text, word)) return false;
                const reference = model.reference(at) orelse return null;
                const d = reference.declaration orelse return null;
                const record = model.declarations[@backingInt(d)];
                switch (record.kind) {
                    .parameter => {
                        if (model.scopes[@backingInt(record.scope)].node != o.whole) return false;
                        const here = o.facts.parameterPosition(o.function.file, o.function, record.token) orelse return null;
                        return here == o.position;
                    },
                    .variable => {
                        if (!o.facts.ownLocal(o.function.file, o.whole, at)) return false;
                        const variable = tree.fullVarDecl(record.node) orelse return null;
                        if (tree.tokenTag(variable.ast.mut_token) == .keyword_const) {
                            return o.address(variable.ast.init_node.unwrap() orelse return null, depth + 1);
                        }
                        // A `var`: what each value it is given may be (`givenTo`).
                        var out: ?bool = false;
                        for ((try o.facts.givenTo(.{ .file = o.function.file, .index = d }, false)) orelse return null) |given| {
                            out = anyOf(out, try o.address(given.node, depth + 1));
                        }
                        return out;
                    },
                    .function => return false,
                    .capture => return o.captured(record, depth + 1),
                    else => return null,
                }
            },
            .call_one, .call_one_comma, .call, .call_comma => {
                // What a callee's result may hold of what it is given (`returnsAddress`).
                const call = (try calls.at(o.facts, o.function.file, at)) orelse return null;
                const args = switch (call.args) {
                    .known => |each| each,
                    .unknown => return null,
                };
                const functions: []const Decl = switch (call.callee) {
                    .function => |function| &.{function},
                    .choice => |each| each,
                    .any => &.{},
                };
                var out: ?bool = false;
                for (args, 0..) |arg, k| {
                    const held = try o.argument(call, k, arg, depth + 1);
                    if (held == false) continue;
                    if (call.callee == .any) return null;
                    for (functions) |function| out = anyOf(out, bothOf(held, try o.facts.returnsAddress(function, k, o.reaching)));
                }
                return out;
            },
            .@"if", .if_simple => {
                const branch = tree.fullIf(at).?; // unreachable: the tag is an if's
                const otherwise = branch.ast.else_expr.unwrap() orelse return null;
                return anyOf(try o.address(branch.ast.then_expr, depth + 1), try o.address(otherwise, depth + 1));
            },
            .@"switch", .switch_comma => {
                const whole = tree.fullSwitch(at).?; // unreachable: the tag is a switch's
                var out: ?bool = false;
                for (whole.ast.cases) |case| out = anyOf(out, try o.address(tree.fullSwitchCase(case).?.ast.target_expr, depth + 1));
                return out;
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                var buffer: [2]Ast.Node.Index = undefined;
                var out: ?bool = false;
                for (builtinArgs(tree, at, &buffer)) |arg| out = anyOf(out, try o.address(arg, depth + 1));
                return if (out == false) false else null;
            },
            else => {
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullStructInit(&buffer, at)) |literal| {
                    var out: ?bool = false;
                    for (literal.ast.fields) |field| out = anyOf(out, try o.address(field, depth + 1));
                    return out;
                }
                if (tree.fullArrayInit(&buffer, at)) |literal| {
                    var out: ?bool = false;
                    for (literal.ast.elements) |item| out = anyOf(out, try o.address(item, depth + 1));
                    return out;
                }
                return null;
            },
        }
    }

    /// Whether a capture may be or hold such an address: an element of a loop's input, by value
    /// or by its address; the payload of what an `if`, a `while` or a `switch` reads, or its
    /// address. An error, an index and a tag hold none.
    fn captured(o: Own, record: Model.Declaration, depth: u8) ResolveError!?bool {
        if (depth >= depth_limit) return null;
        const tree = o.syntax();
        const by_address = tree.tokenTag(record.token - 1) == .asterisk;
        if (tree.fullFor(record.node)) |loop| {
            const position = Model.capturePosition(tree, loop, record.token) orelse return null;
            if (position >= loop.ast.inputs.len) return null;
            const input = loop.ast.inputs[position];
            if (tree.nodeTag(input) == .for_range) return false;
            const pointing = accesses.pointing(try o.facts.resolve(o.function.file, input));
            if (by_address) return if (pointing) o.address(input, depth + 1) else o.place(input, depth + 1);
            // An element read out of memory, as `input[i]` is.
            if (pointing and !o.reaching) return false;
            return o.address(input, depth + 1);
        }
        const source: Ast.Node.Index = source: {
            if (tree.fullIf(record.node)) |branch| {
                if (branch.payload_token == null or record.token != (if (tree.tokenTag(branch.payload_token.?) == .asterisk) branch.payload_token.? + 1 else branch.payload_token.?)) return false;
                break :source branch.ast.cond_expr;
            }
            if (tree.fullWhile(record.node)) |loop| {
                if (loop.payload_token == null or record.token != (if (tree.tokenTag(loop.payload_token.?) == .asterisk) loop.payload_token.? + 1 else loop.payload_token.?)) return false;
                break :source loop.ast.cond_expr;
            }
            if (tree.fullSwitchCase(record.node)) |case| {
                const named = case.payload_token orelse return null;
                if (record.token != (if (tree.tokenTag(named) == .asterisk) named + 1 else named)) return false;
                const parent = o.lexicon().parentOf(record.node) orelse return null;
                break :source (tree.fullSwitch(parent) orelse return null).ast.condition;
            }
            // A `catch`'s error.
            if (tree.nodeTag(record.node) == .@"catch") return false;
            return null;
        };
        return if (by_address) o.place(source, depth + 1) else o.address(source, depth + 1);
    }

    /// Whether what a call is given at `k` may be or hold such an address: a receiver it binds
    /// is given by its address where it is held by value (`self.bits.setUnion(b)` takes
    /// `&self.bits`).
    fn argument(o: Own, call: calls.Call, k: usize, arg: Ast.Node.Index, depth: u8) ResolveError!?bool {
        if (k == 0 and call.receiver == .bound and !accesses.pointing(try o.facts.resolve(o.function.file, arg))) return o.place(arg, depth);
        return o.address(arg, depth);
    }

    /// Whether a call stores, into that memory, what `given` names: one handed the address of
    /// the memory at a position and the value at another (or the same), whose callee may store
    /// the one's value through the other.
    fn handed(o: Own, given: Own, node: Ast.Node.Index) ResolveError!?bool {
        const call = (try calls.at(o.facts, o.function.file, node)) orelse return null;
        const args = switch (call.args) {
            .known => |each| each,
            .unknown => {
                var buffer: [1]Ast.Node.Index = undefined;
                const full = o.syntax().fullCall(&buffer, node).?; // unreachable: the tag is a call's
                var into: ?bool = false;
                var value: ?bool = false;
                for (full.ast.params) |arg| {
                    into = anyOf(into, try o.address(arg, 0));
                    value = anyOf(value, try given.address(arg, 0));
                }
                return if (into == false or value == false) false else null;
            },
        };
        const functions: []const Decl = switch (call.callee) {
            .function => |function| &.{function},
            .choice => |each| each,
            .any => &.{},
        };
        var out: ?bool = false;
        for (args, 0..) |arg, at| {
            const into = try o.argument(call, at, arg, 0);
            if (into == false) continue;
            for (args, 0..) |held, from| {
                const value = try given.argument(call, from, held, 0);
                if (value == false) continue;
                if (call.callee == .any) return null;
                for (functions) |function| out = anyOf(out, bothOf(bothOf(into, value), try o.facts.storesAddress(function, at, from)));
                if (out == true) return true;
            }
        }
        return out;
    }
};

/// Whether an address is taken only to be dropped: `_ = &f`.
fn dropped(self: *Facts, site: accesses.Site) bool {
    const tree = &self.project.at(site.file).file.tree;
    const parent = self.project.at(site.file).model.parentOf(site.node) orelse return false;
    if (tree.nodeTag(site.node) != .address_of or tree.nodeTag(parent) != .assign) return false;
    const lhs, const rhs = tree.nodeData(parent).node_and_node;
    return rhs == site.node and tree.nodeTag(lhs) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(lhs)), "_");
}

/// Whether `node`'s value is a pointer by its form, whatever its type resolves to: an address
/// taken (`&x`), or a builtin Zig types only as a pointer (`@ptrFromInt`, `@ptrCast`,
/// `@alignCast`, `@constCast`, `@volatileCast`, `@fieldParentPtr`), through `@as` and parentheses.
/// A local it initialises is a pointer, never memory of its own a slice of it would be.
pub fn makesPointer(self: *const Facts, file: Project.FileId, node: Ast.Node.Index) bool {
    const tree = &self.project.at(file).file.tree;
    var at = node;
    while (true) switch (tree.nodeTag(at)) {
        .grouped_expression => at = tree.nodeData(at).node_and_token[0],
        .address_of => return true,
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(at));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = builtinArgs(tree, at, &buffer);
            if (std.mem.eql(u8, name, "@as") and args.len == 2) {
                at = args[1];
                continue;
            }
            for ([_][]const u8{ "@ptrFromInt", "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@fieldParentPtr" }) |made| {
                if (std.mem.eql(u8, name, made)) return true;
            }
            return false;
        },
        else => return false,
    };
}

/// What a source of a callable value gives through the casts that keep an address: `@ptrCast`,
/// `@alignCast`, `@constCast`, `@volatileCast` and `@as` of it call what it points at.
fn throughCasts(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Ast.Node.Index {
    const tree = &self.project.at(file).file.tree;
    var at = node;
    while (true) {
        switch (tree.nodeTag(at)) {
            .grouped_expression => at = tree.nodeData(at).node_and_token[0],
            .builtin_call_two, .builtin_call_two_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(at));
                var buffer: [2]Ast.Node.Index = undefined;
                const args = builtinArgs(tree, at, &buffer);
                if (std.mem.eql(u8, name, "@as") and args.len == 2) {
                    at = args[1];
                    continue;
                }
                for ([_][]const u8{ "@ptrCast", "@alignCast", "@constCast", "@volatileCast" }) |cast| {
                    if (std.mem.eql(u8, name, cast) and args.len == 1) break;
                } else return at;
                at = args[0];
            },
            else => return at,
        }
    }
}

/// The variable `variable` of `const a, const b = value;`: the field of a tuple at its
/// position, or an element of an array.
fn destructured(self: *Facts, file: Project.FileId, whole: Ast.Node.Index, variable: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const full = tree.assignDestructure(whole);
    const position = std.mem.findScalar(Ast.Node.Index, full.ast.variables, variable) orelse return .{ .unknown = .unsupported };
    const value = try self.resolve(file, full.ast.value_expr);
    return self.destructuredAt(value, position);
}

/// Element `position` of a tuple or an array `value` is destructured into.
fn destructuredAt(self: *Facts, value: Value, position: usize) ResolveError!Value {
    switch (value) {
        .array => |each| return each.*,
        .reified => |built| return self.instance(built.fields.*),
        .literal => |literal| {
            const parts = try self.literalParts(literal);
            return if (position < parts.len) parts[position] else .{ .unknown = .unsupported };
        },
        .alternatives => |each| {
            const mapped = try self.gpa.alloc(Value, each.len);
            for (each, mapped) |one, *out| out.* = try self.destructuredAt(one, position);
            return self.choose(mapped);
        },
        .instance => |tuple| {
            const model = &self.project.at(tuple.file).model;
            const source = &self.project.at(tuple.file).file.tree;
            var buffer: [2]Ast.Node.Index = undefined;
            const container = source.fullContainerDecl(&buffer, model.scopes[@backingInt(tuple.scope)].node) orelse return .{ .unknown = .unsupported };
            var at: usize = 0;
            for (container.ast.members) |item| {
                const field = model.containerField(source, item) orelse continue;
                if (!field.ast.tuple_like) return .{ .unknown = .unsupported };
                if (at == position) return self.instance(try self.resolve(tuple.file, field.ast.type_expr.unwrap() orelse return .{ .unknown = .unsupported }));
                at += 1;
            }
            return .{ .unknown = .unsupported };
        },
        .unknown => return value,
        else => return .{ .unknown = .unsupported },
    }
}

/// The values an anonymous literal holds: its fields' or its elements', in order.
/// An argument as a reading binds it: a tuple literal (`.{ x, y }`) is the first one met whose
/// elements read alike, as Zig gives tuples of the same element types one type, so a generic
/// handed `.{ n }` at two calls is one instantiation. A struct literal with named fields is its
/// own type (`same`) and stays.
fn boundArgument(self: *Facts, value: Value) ResolveError!Value {
    if (value != .literal) return value;
    const tree = &self.project.at(value.literal.file).file.tree;
    switch (tree.nodeTag(value.literal.node)) {
        .array_init_dot, .array_init_dot_comma, .array_init_dot_two, .array_init_dot_two_comma => {},
        else => return value,
    }
    const parts = try self.literalParts(value.literal);
    const memory = try self.memo(Tuples);
    for (memory.kept.items) |kept| {
        if (kept.parts.len != parts.len) continue;
        for (kept.parts, parts) |one, other| {
            if (!sameValue(one, other)) break;
        } else return .{ .literal = kept.key };
    }
    try memory.kept.append(self.gpa, .{ .key = value.literal, .parts = parts });
    return value;
}

const Tuples = struct { kept: std.ArrayList(struct { key: Key, parts: []const Value }) = .empty };

pub fn literalParts(self: *Facts, literal: Key) ResolveError![]const Value {
    const tree = &self.project.at(literal.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const nodes = if (tree.fullStructInit(&buffer, literal.node)) |full| full.ast.fields else if (tree.fullArrayInit(&buffer, literal.node)) |full| full.ast.elements else return &.{};
    const parts = try self.gpa.alloc(Value, nodes.len);
    for (nodes, parts) |node, *part| part.* = try self.resolve(literal.file, node);
    return parts;
}

fn memberName(self: *Facts, raw: []const u8) ResolveError![]const u8 {
    return Model.identifier(self.gpa, raw);
}

/// The `T` this run keeps, made with its defaults the first time it is asked for: what a rule
/// computes once for the whole project and reads from each file's check. A type is its own key,
/// so one rule's state is never another's. It lives as long as the run, or until `forget` drops
/// it, unless `T` declares `lasting`: what it holds must then be complete whatever a later
/// `forget` drops, or mark itself as not.
pub fn memo(self: *Facts, comptime T: type) ResolveError!*T {
    const key = comptime std.hash.Wyhash.hash(0, @typeName(T));
    if (self.walk != null) try self.walked.put(self.gpa, key, {});
    const memos = if (@hasDecl(T, "lasting")) &self.lasting else &self.memos;
    const entry = try memos.getOrPut(self.gpa, key);
    if (!entry.found_existing) {
        const made = try self.gpa.create(T);
        made.* = .{};
        entry.value_ptr.* = made;
    }
    return @ptrCast(@alignCast(entry.value_ptr.*)); // aegis: internal(A019): the key is this type's own name.
}

/// The member accesses (`x.name`) in the program's files (`program`) that spell `name`, each a
/// `field_access` node: an index built once, for rules that follow one member across files.
pub fn memberUses(self: *Facts, name: []const u8) ResolveError![]const Key {
    if (self.member_uses == null) {
        var index: std.StringHashMapUnmanaged(std.ArrayList(Key)) = .empty;
        for (self.project.sources) |*source| {
            if (!try self.program(source.id)) continue;
            const file = source.id;
            const tree = &source.file.tree;
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                if (tag != .field_access) continue;
                const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                const spelled = try self.memberName(tree.tokenSlice(tree.nodeData(node).node_and_token[1]));
                const entry = try index.getOrPut(self.gpa, spelled);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(self.gpa, .{ .file = file, .node = node });
            }
        }
        self.member_uses = index;
    }
    return if (self.member_uses.?.get(name)) |list| list.items else &.{};
}

/// A file's own container: the struct the file is.
pub fn rootOf(self: *const Facts, file: Project.FileId) Container {
    return .{ .file = file, .scope = self.project.at(file).model.root() };
}

pub fn member(self: *const Facts, container: Container, name: []const u8) ?Decl {
    const model = &self.project.at(container.file).model;
    if (model.scopes[@backingInt(container.scope)].names.get(name)) |decl| return .{ .file = container.file, .index = decl };
    for (model.declarations, 0..) |decl, i| if (decl.kind == .field and decl.scope == container.scope and std.mem.eql(u8, decl.name, name)) return .{ .file = container.file, .index = @fromBackingInt(@intCast(i)) };
    return null;
}

/// The fields a container declares, in order: each file's read once for the run, by one pass
/// over its declarations (`member` and a walk over a type's fields find them here, not by
/// scanning every declaration of its file).
pub fn fieldsOf(self: *Facts, holder: Container) ResolveError![]const Model.Declaration.Id {
    const index = try self.memo(FieldIndex);
    const entry = try index.files.getOrPut(self.gpa, holder.file);
    if (!entry.found_existing) {
        entry.value_ptr.* = .empty;
        for (self.project.at(holder.file).model.declarations, 0..) |decl, i| {
            if (decl.kind != .field) continue;
            const fields = try entry.value_ptr.getOrPut(self.gpa, decl.scope);
            if (!fields.found_existing) fields.value_ptr.* = .empty;
            try fields.value_ptr.append(self.gpa, @fromBackingInt(@intCast(i)));
        }
    }
    return if (entry.value_ptr.get(holder.scope)) |fields| fields.items else &.{};
}

const FieldIndex = struct {
    files: std.AutoHashMapUnmanaged(Project.FileId, std.AutoHashMapUnmanaged(Model.Scope.Id, std.ArrayList(Model.Declaration.Id))) = .empty,
};

/// What a probe of `fieldsHold` reads of one field: the kind it looks for, none of it, a form
/// it does not read (`maybe`), or a container whose own fields say (`holder`).
pub const Probed = union(enum) { is, none, maybe, holder: Container };

/// Where a type's fields hold what a probe looks for: at a path of field names (`.at`, `"ctx.io"`,
/// the first in declaration order), nowhere, or maybe.
pub const Holding = union(enum) { none, at: []const u8, maybe };

/// Whether a value of the container `holder` holds, in its fields and theirs, what `probe` looks
/// for: a type's property (does it hold an `Io`, memory with a length), read once per probe and
/// type for the run. A probe's type declares `Key`, what tells its probes apart for the run
/// (the probe's `key`), and `Error`, what its reading may fail with; `of(probe, facts, field,
/// value)` says what a field (its declaration, and the value Facts gives it, never unknown)
/// holds. A field whose value does not resolve may hold it (`maybe`): an
/// unknown never clears. A container reached again through its own fields (`next: ?*Node`) adds nothing of
/// its own there; an answer of none read meanwhile is not kept, being read again where asked,
/// and none read once the file's fact budget is spent.
pub fn fieldsHold(self: *Facts, probe: anytype, comptime of: ProbeOf(@TypeOf(probe)), holder: Container) (ResolveError || @TypeOf(probe).Error)!Holding {
    const state = try self.memo(HoldsMemo(@TypeOf(probe).Key));
    const at: HoldsMemo(@TypeOf(probe).Key).Type = .{ .key = probe.key, .file = holder.file, .scope = holder.scope, .made = holder.made_by };
    if (state.found.get(at)) |known| return known;
    if (state.open.contains(at)) {
        state.met_open += 1;
        return .none;
    }
    try state.open.put(self.gpa, at, {});
    const met_open = state.met_open;
    const out = try self.fieldsHoldOnce(probe, of, holder);
    _ = state.open.remove(at);
    if ((out != .none or state.met_open == met_open) and self.remaining != 0) try state.found.put(self.gpa, at, out);
    return out;
}

/// What a probe of `fieldsHold` is asked of one field: the probe, Facts, the field's
/// declaration and the value Facts gives it, never unknown.
pub fn ProbeOf(comptime Probe: type) type {
    return fn (Probe, *Facts, Decl, Value) (ResolveError || Probe.Error)!Probed;
}

fn HoldsMemo(comptime ProbeKey: type) type {
    return struct {
        /// A type a type function made is read with that call's bindings (`made`): each making
        /// apart.
        const Type = struct { key: ProbeKey, file: Project.FileId, scope: Model.Scope.Id, made: ?*const Made };
        found: std.AutoHashMapUnmanaged(Type, Holding) = .empty,
        open: std.AutoHashMapUnmanaged(Type, void) = .empty,
        /// How many times one still being read was met again.
        met_open: usize = 0,
    };
}

fn fieldsHoldOnce(self: *Facts, probe: anytype, comptime of: ProbeOf(@TypeOf(probe)), holder: Container) (ResolveError || @TypeOf(probe).Error)!Holding {
    var maybe = false;
    for (try self.fieldsOf(holder)) |index| {
        const field: Decl = .{ .file = holder.file, .index = index };
        const name = self.project.at(holder.file).model.declarations[@backingInt(index)].name;
        // A field whose value does not resolve may hold anything; a probe reads resolved values.
        // One of a type a type function made is read with that call's bindings (memberOf).
        const value = try self.memberOf(holder, field);
        if (value == .unknown) {
            maybe = true;
            continue;
        }
        switch (try of(probe, self, field, value)) {
            .is => return .{ .at = name },
            .none => {},
            .maybe => maybe = true,
            .holder => |inner| switch (try self.fieldsHold(probe, of, inner)) {
                .at => |through| return .{ .at = try self.gpa.print("{s}.{s}", .{ name, through }) },
                .maybe => maybe = true,
                .none => {},
            },
        }
    }
    return if (maybe) .maybe else .none;
}

/// What a field `len` or `ptr` reads. `memory`: the length (or the address) of an array or a
/// slice (or one a single pointer reaches) whose elements take room, so one object's count of
/// them is below half the address space. `unsized`: a length of memory whose elements may
/// take none (`[]const void`, a struct of no field that takes room, an array of an unknown
/// count), any `usize`. `field`: no memory's, a field a container declares by that name, or
/// a receiver whose type does not resolve, which holds what that field holds.
pub const Length = enum { field, memory, unsized };

pub fn memoryField(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Length {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(node) != .field_access) return .field;
    const receiver, const name = tree.nodeData(node).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(name), "len") and !std.mem.eql(u8, tree.tokenSlice(name), "ptr")) return .field;
    return self.lengthOfValue(try self.resolve(file, receiver), tree.tokenSlice(name));
}

/// Whether the memory a value of `value`'s type holds (a function's result through its error
/// union or optional) has a length below half the address space: `memoryField`'s `memory`.
pub fn sizedMemory(self: *Facts, value: Value) ResolveError!bool {
    return switch (value) {
        .error_union, .optional => |inner| self.sizedMemory(inner.*),
        else => try self.lengthOfValue(value, "len") == .memory,
    };
}

/// What a field `name` read on a value of `value` reads (`memoryField`).
pub fn lengthOfValue(self: *Facts, value: Value, name: []const u8) ResolveError!Length {
    switch (value) {
        // A string literal's bytes.
        .scalar => return .memory,
        .array => |each| return if (try self.sized(each.*, 0)) .memory else .unsized,
        // A slice's `.len` is its count, whatever it holds.
        .pointer => |inner| if (inner.size == .slice and inner.child.* == .unknown) return .unsized else switch (inner.child.*) {
            // A single pointer to a container reads its field; a slice of one, its count.
            // The value is the same for both, so a container that declares `len` is read
            // as declaring it.
            .instance, .container => |k| {
                if (self.member(k, name) != null) return .field;
                return if (try self.sized(inner.child.*, 0)) .memory else .unsized;
            },
            // A pointer to an array or a slice, or a slice of them: the count is of
            // what the inner one holds for the first, of the inner one for the second.
            // An array's own size is its count's, which the value does not hold.
            .array => return .unsized,
            .unknown, .literal, .reified, .reflected, .alternatives => return .field,
            else => return if (try self.sized(inner.child.*, 0)) .memory else .unsized,
        },
        .alternatives => |each| {
            var out: Length = .memory;
            for (each) |one| switch (try self.lengthOfValue(one, name)) {
                .field => return .field,
                .unsized => out = .unsized,
                .memory => {},
            };
            return out;
        },
        else => return .field,
    }
}

/// Whether a value of `value`'s type takes room: a known primitive wider than zero bits, a
/// pointer to such, an optional, an error, or a container with a field (two for an enum)
/// that takes room. What does not resolve may take none.
fn sized(self: *Facts, value: Value, depth: usize) ResolveError!bool {
    if (depth > 4) return false;
    switch (value) {
        .primitive => |p| {
            if (p.len > 1 and (p[0] == 'u' or p[0] == 'i')) if (std.fmt.parseInt(u16, p[1..], 10)) |bits| return bits > 0 else |_| {}; // glint-ignore: Z026 -- no integer type's name (usize, isize): the names below decide it
            for ([_][]const u8{ "bool", "usize", "isize", "f16", "f32", "f64", "f80", "f128", "c_char", "c_short", "c_ushort", "c_int", "c_uint", "c_long", "c_ulong", "c_longlong", "c_ulonglong", "c_longdouble", "anyerror" }) |one| if (std.mem.eql(u8, p, one)) return true;
            return false;
        },
        .pointer => |inner| return (inner.child.* == .primitive and std.mem.eql(u8, inner.child.primitive, "anyopaque")) or try self.sized(inner.child.*, depth + 1),
        .optional, .error_union, .error_set, .function, .fn_type => return true,
        .instance, .container => |k| {
            const model = &self.project.at(k.file).model;
            const tree = &self.project.at(k.file).file.tree;
            const scope = model.scopes[@backingInt(k.scope)];
            if (scope.kind != .container) return false;
            const is_enum = tree.tokenTag(tree.nodeMainToken(scope.node)) == .keyword_enum;
            var buffer: [2]Ast.Node.Index = undefined;
            const container = tree.fullContainerDecl(&buffer, scope.node) orelse return false;
            var fields: usize = 0;
            for (container.ast.members) |item| {
                const field = model.containerField(tree, item) orelse continue;
                fields += 1;
                if (is_enum) continue;
                const t = field.ast.type_expr.unwrap() orelse continue;
                if (try self.sized(try self.instance(try self.resolve(k.file, t)), depth + 1)) return true;
            }
            return is_enum and fields > 1;
        },
        else => return false,
    }
}

/// Whether a value of the type written at `type_node` has a length or holds memory that has
/// one: a slice, an array or a pointer to one, and a pointer, struct or union with a field
/// that does (a field read through it carries its length), or memory a cast may give any
/// type (`*anyopaque`). A number, `bool`, an enum, an error set, and a single-item pointer,
/// an optional or a struct of those hold none; a struct reached again through its own fields
/// (`next: ?*Node`) adds none of its own. A type that does not resolve, or one nested this
/// deep, may.
pub fn holdsLength(self: *Facts, file: Project.FileId, type_node: Ast.Node.Index) ResolveError!bool {
    var open: OpenTypes = .{};
    return self.writtenHoldsLength(file, type_node, &open, 0);
}

/// The structs whose fields a `holdsLength` reading is within.
const OpenTypes = struct { items: [8]Container = undefined, len: usize = 0 };

fn writtenHoldsLength(self: *Facts, file: Project.FileId, type_node: Ast.Node.Index, open: *OpenTypes, depth: usize) ResolveError!bool {
    if (depth > 16) return true;
    const tree = &self.project.at(file).file.tree;
    if (tree.fullPtrType(type_node)) |pointer| {
        if (pointer.size != .one) return true;
        return self.writtenHoldsLength(file, pointer.ast.child_type, open, depth + 1);
    }
    switch (tree.nodeTag(type_node)) {
        .optional_type => return self.writtenHoldsLength(file, tree.nodeData(type_node).node, open, depth + 1),
        .grouped_expression => return self.writtenHoldsLength(file, tree.nodeData(type_node).node_and_token[0], open, depth + 1),
        else => {},
    }
    return self.valueHoldsLength(try self.resolve(file, type_node), open, depth + 1);
}

/// `holdsLength` by what a type resolves to, where its spelling does not show it: a pointer
/// read this way may be a slice.
fn valueHoldsLength(self: *Facts, value: Value, open: *OpenTypes, depth: usize) ResolveError!bool {
    if (depth > 16) return true;
    switch (value) {
        .primitive => |p| return std.mem.eql(u8, p, "anyopaque"),
        .error_set, .scalar, .function, .fn_type => return false,
        .optional, .error_union => |inner| return self.valueHoldsLength(inner.*, open, depth + 1),
        .container, .instance => |k| {
            const scope = self.project.at(k.file).model.scopes[@backingInt(k.scope)];
            if (scope.kind != .container and scope.kind != .file) return true;
            const kind = self.kindOf(k) orelse return true;
            if (kind == .keyword_enum) return false;
            if (kind == .keyword_opaque) return true;
            for (open.items[0..open.len]) |outer| if (outer.file == k.file and outer.scope == k.scope) return false;
            if (open.len == open.items.len) return true;
            open.items[open.len] = k;
            open.len += 1;
            defer open.len -= 1;
            const tree = &self.project.at(k.file).file.tree;
            var buffer: [2]Ast.Node.Index = undefined;
            const members = if (scope.node == .root) tree.rootDecls() else (tree.fullContainerDecl(&buffer, scope.node) orelse return true).ast.members;
            for (members) |item| {
                const field = tree.fullContainerField(item) orelse continue;
                const t = field.ast.type_expr.unwrap() orelse return true;
                if (try self.writtenHoldsLength(k.file, t, open, depth + 1)) return true;
            }
            return false;
        },
        .alternatives => |each| {
            for (each) |one| if (try self.valueHoldsLength(one, open, depth + 1)) return true;
            return false;
        },
        else => return true,
    }
}

/// The container an untyped literal or a declaration literal at `node` takes (`.{…}`,
/// `.init(...)`): the one the type its place gives (`literalType`) is, through the error union
/// or optional around it. Null where that type is no one container.
pub fn resultContainer(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Container {
    return heldContainer(try self.literalType(file, node));
}

/// The container a type or a value is, through the error union or optional around it.
fn heldContainer(value: Value) ?Container {
    return switch (value) {
        .container, .instance => |container| container,
        .error_union, .optional => |inner| heldContainer(inner.*),
        else => null,
    };
}

/// An array type, its parts nodes of `file`: its length (null for `_`, which its literal's
/// elements give), its element's type, and its sentinel.
pub const ArrayType = struct { file: Project.FileId, length: ?Ast.Node.Index, element: Ast.Node.Index, sentinel: ?Ast.Node.Index };

/// The array type `node` writes, through parentheses, `comptime` and the constants that name one
/// (`const Buf = [32]u8`); null for any other expression, or a name that does not resolve. Its
/// length is a node: what it counts is its constant value.
pub fn arrayType(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?ArrayType {
    var at_file = file;
    var at = node;
    for (0..16) |_| {
        const tree = &self.project.at(at_file).file.tree;
        if (tree.fullArrayType(at)) |array| {
            const count = array.ast.elem_count;
            const inferred = tree.nodeTag(count) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(count)), "_");
            return .{ .file = at_file, .length = if (inferred) null else count, .element = array.ast.elem_type, .sentinel = array.ast.sentinel.unwrap() };
        }
        switch (tree.nodeTag(at)) {
            .grouped_expression => at = tree.nodeData(at).node_and_token[0],
            .@"comptime" => at = tree.nodeData(at).node,
            .identifier, .field_access => {
                // A name that does not resolve shows no array type: null, as for none.
                const decl = switch (try self.definition(at_file, at)) {
                    .decl => |found| found,
                    .none, .unknown => return null,
                };
                const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
                if (record.kind != .variable) return null;
                const held = &self.project.at(decl.file).file.tree;
                const constant = held.fullVarDecl(record.node) orelse return null;
                if (held.tokenTag(constant.ast.mut_token) != .keyword_const) return null;
                at_file = decl.file;
                at = constant.ast.init_node.unwrap() orelse return null;
            },
            else => return null,
        }
    }
    return null;
}

/// The memory whose length `node` reads, through parentheses: `x` of `x.len` where `x` is an
/// array, a slice or a pointer to an array (`memoryField`). Null for anything else, a field a
/// container declares by that name among them, and where what `x` is does not resolve.
pub fn lengthOf(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Ast.Node.Index {
    const tree = &self.project.at(file).file.tree;
    const at = ungrouped(tree, node);
    if (tree.nodeTag(at) != .field_access) return null;
    const holder, const member_token = tree.nodeData(at).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(member_token), "len")) return null;
    return if (try self.memoryField(file, at) != .field) holder else null;
}

pub fn definition(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Named {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(node) == .identifier or tree.nodeTag(node) == .test_decl) {
        const ref = self.project.at(file).model.reference(node) orelse return .none;
        if (ref.declaration) |decl| return .{ .decl = .{ .file = file, .index = decl } };
        return switch (ref.unknown orelse .unresolved) {
            // `u8`, `true`, `null`: the language's, no declaration.
            .primitive => .none,
            .invalid_lowering => .{ .unknown = .invalid_front_end },
            .unresolved, .before_declaration, .literal_context => .{ .unknown = .unresolved },
        };
    }
    if (tree.nodeTag(node) == .field_access) {
        const data = tree.nodeData(node).node_and_token;
        const value = try self.resolve(file, data[0]);
        const holder = if (value == .pointer) value.pointer.child.* else value;
        const container = switch (holder) {
            .container, .instance => |c| c,
            .unknown => |why| return .{ .unknown = why },
            // A number, a truth value, an error set: no declaration is a member of one.
            .primitive, .scalar, .error_set => return .none,
            // A choice of holders, each with its own member; any other value a member of which
            // is not read here.
            else => return .{ .unknown = .unsupported },
        };
        return .of(self.member(container, try self.memberName(tree.tokenSlice(data[1]))));
    }
    return .none;
}

/// Literal reflection binds a declaration only on a concrete, resolved container.
pub fn reflected(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Named {
    const tree = &self.project.at(file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, node, &buffer);
    if (args.len != 2) return .none;
    // The one name it spells (`fieldName`): a string, a `const` holding one, an enum literal; a
    // name it ranges over or computes is not one known here.
    const name = switch (try self.fieldName(file, args[1])) {
        .name => |name| name,
        .each_of, .names, .computed => return .{ .unknown = .comptime_dependent },
    };
    // `@field(p, "name")` on a single pointer names its pointee's member.
    const resolved = try self.resolve(file, args[0]);
    const value = if (resolved == .pointer) resolved.pointer.child.* else resolved;
    const container = switch (value) {
        .container, .instance => |c| c,
        .unknown => |why| return .{ .unknown = why },
        .primitive, .scalar, .error_set => return .none,
        else => return .{ .unknown = .unsupported },
    };
    if (container.symbolic) return .{ .unknown = .comptime_dependent };
    return .of(self.member(container, name));
}

/// What a decl literal names (`.fromMilliseconds(ms)`, `.zero`, a literal's `.{ .f = v }`
/// field): the member so named of the type its place gives it, through an optional, an error
/// union and a pointer. None where that type has none; unknown where it does not resolve.
pub fn literalDeclaration(self: *Facts, file: Project.FileId, node: Ast.Node.Index, name: []const u8) ResolveError!Named {
    const tree = &self.project.at(file).file.tree;
    // A called one (`.init(x)`) is a function of the type the call's place gives, read as an
    // uncalled one's is: through an optional, an error union and a pointer (std's SafeAllocator
    // `const b: *Bucket = .of(s, p)` calls `Bucket.of`).
    const call_node = called: {
        if (tree.nodeTag(node) != .enum_literal) break :called null;
        const parent = self.project.at(file).model.parentOf(node) orelse break :called null;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, parent) orelse break :called null;
        break :called if (call.ast.fn_expr == node) parent else null;
    };
    var holder = try self.literalType(file, call_node orelse node);
    while (true) holder = switch (holder) {
        .pointer => |inner| inner.child.*,
        .optional, .error_union => |inner| inner.*,
        else => break,
    };
    const container = switch (holder) {
        .container, .instance => |c| c,
        .unknown => |why| return .{ .unknown = why },
        // No type a declaration could be a member of: an anonymous literal, a number; for a
        // call's place, the function it names is not known.
        else => return if (call_node != null) .{ .unknown = .unresolved } else .none,
    };
    return .of(self.member(container, name));
}

/// Follows only declaration aliases, keeping the final declaration's provenance.
/// Cycles, computed expressions and unsupported comptime retain uncertainty.
pub fn origin(self: *Facts, start: Decl) ResolveError!Named {
    var current = start;
    var visited: aegis.bounded.Array(Decl, 128) = .init;
    while (true) {
        for (visited.constItems()) |earlier| if (std.meta.eql(earlier, current)) return .{ .unknown = .cycle };
        // More aliases than are followed: uncertain, as a cycle is.
        visited.appendSlice(&.{current}) catch return .{ .unknown = .budget };
        const record = self.project.at(current.file).model.declarations[@backingInt(current.index)];
        if (record.kind != .variable) return .{ .decl = current };
        const tree = &self.project.at(current.file).file.tree;
        const variable = tree.fullVarDecl(record.node).?;
        const expr = variable.ast.init_node.unwrap() orelse return .{ .decl = current };
        if (tree.nodeTag(expr) != .identifier and tree.nodeTag(expr) != .field_access) return .{ .decl = current };
        current = switch (try self.definition(current.file, expr)) {
            .decl => |next| next,
            // An alias of a primitive (`const Int = u8`) is its own origin.
            .none => return .{ .decl = current },
            .unknown => |why| return .{ .unknown = why },
        };
    }
}

/// A value of the type `value` names: an instance of a container, and through a pointer,
/// optional, error union or array type, the same wrapper around an instance of its payload
/// (`E!Self` gives an error union whose payload is a `Self`).
fn instance(self: *Facts, value: Value) ResolveError!Value {
    return switch (value) {
        .container => |c| .{ .instance = c },
        .reified => |built| .{ .reified = .{ .fields = built.fields, .value = true } },
        .pointer => |inner| try self.pointerTo(try self.instance(inner.child.*), inner.size),
        .optional => |inner| .{ .optional = try self.boxed(try self.instance(inner.*)) },
        .error_union => |inner| .{ .error_union = try self.boxed(try self.instance(inner.*)) },
        .array => |inner| .{ .array = try self.boxed(try self.instance(inner.*)) },
        // No value has type `noreturn`: a choice of types gives values of the others.
        .alternatives => |each| blk: {
            var mapped: std.ArrayList(Value) = .empty;
            for (each) |one| if (one != .primitive or !std.mem.eql(u8, one.primitive, "noreturn")) try mapped.append(self.gpa, try self.instance(one));
            if (mapped.items.len == 1) break :blk mapped.items[0];
            break :blk .{ .alternatives = mapped.items };
        },
        else => value,
    };
}

/// One value of `values`, each resolved: an unknown if any is, the value if they agree, else
/// the alternatives. A part identical to one kept (`identical`: no reader can tell the two
/// apart) is that one, so what is kept grows with what is new in a choice, never with how many
/// routes gave the same value, and each part is compared with those alone; one of the same
/// type (`same`) is that one too. Each part kept
/// past the first is one of the run's resolutions (`remaining`): a choice that grows past the
/// budget is unknown(budget). One value alone costs nothing, as it did.
fn choose(self: *Facts, values: []const Value) ResolveError!Value {
    var kept: std.ArrayList(Value) = .empty;
    // An unknown that a binding would not settle comes first: the choice is unknown for it.
    for (values) |value| if (value == .unknown and value.unknown != .generic) return value;
    for (values) |value| {
        if (value == .unknown) return value;
        const parts: []const Value = if (value == .alternatives) value.alternatives else &.{value};
        for (parts) |part| {
            for (kept.items) |earlier| {
                if (identical(earlier, part, 0) or same(earlier, part, 0)) break;
            } else {
                // The choice grows: one resolution for each part past the first.
                if (kept.items.len != 0) {
                    if (self.remaining == 0) return self.spent();
                    self.remaining -= 1;
                }
                try kept.append(self.gpa, part);
            }
        }
    }
    // An empty literal (`.{}`, `&.{}`) coerces to the type of a peer it is chosen with: a slice's,
    // a struct's with defaults (`if (found) |list| list.items else &.{}`).
    if (kept.items.len > 1) {
        var peers: usize = 0;
        for (kept.items) |part| if (!self.emptyLiteralValue(part)) {
            kept.items[peers] = part;
            peers += 1;
        };
        if (peers != 0) kept.items.len = peers;
    }
    if (kept.items.len == 0) return .{ .unknown = .unsupported };
    if (kept.items.len == 1) return kept.items[0];
    return .{ .alternatives = kept.items };
}

/// Whether a value is a literal with no type of its own and nothing in it, or a pointer to one.
fn emptyLiteralValue(self: *const Facts, value: Value) bool {
    const literal = switch (value) {
        .literal => |literal| literal,
        .pointer => |inner| if (inner.child.* == .literal) inner.child.literal else return false,
        else => return false,
    };
    return emptyLiteral(&self.project.at(literal.file).file.tree, literal.node);
}

/// `f(value)` for each alternative of `value`, chosen as one.
fn map(self: *Facts, value: Value, context: anytype, comptime f: fn (*Facts, Value, @TypeOf(context)) ResolveError!Value) ResolveError!Value {
    if (value != .alternatives) return f(self, value, context);
    const mapped = try self.gpa.alloc(Value, value.alternatives.len);
    for (value.alternatives, mapped) |one, *out| out.* = try f(self, one, context);
    return self.choose(mapped);
}

/// The type of a value: an instance is of its container; pointers, arrays, optionals and error
/// unions read the same as values and as types here, and a function is its own type.
fn typeOf(self: *Facts, value: Value, _: void) ResolveError!Value {
    return switch (value) {
        .instance => |c| .{ .container = c },
        .reified => |built| .{ .reified = .{ .fields = built.fields } },
        // A pointer's size is a `std.builtin.Type.Pointer.Size`.
        .reflected => |r| if (r.at == .size) self.stdMember(&.{ "builtin", "Type", "Pointer", "Size" }) else value,
        else => value,
    };
}

fn reflect(self: *Facts, of: Value) ResolveError!Value {
    // Each of several types chosen at compile time is reflected on its own.
    if (of == .alternatives) {
        const each = try self.gpa.alloc(Value, of.alternatives.len);
        for (of.alternatives, each) |one, *out| out.* = .{ .reflected = .{ .of = try self.boxed(one), .at = .info } };
        return .{ .alternatives = each };
    }
    return .{ .reflected = .{ .of = try self.boxed(of), .at = .info } };
}

/// `base[index]`: a reflected function's parameter type, or an element.
fn elementOf(self: *Facts, base: Value, tree: *const Ast, index_node: Ast.Node.Index) ResolveError!Value {
    switch (base) {
        .reflected => |r| return (try self.reflectedElement(r, tree, index_node)) orelse .{ .unknown = .unsupported },
        .alternatives => |each| {
            var mapped: std.ArrayList(Value) = .empty;
            for (each) |one| {
                // A function of the choice with no parameter there is one no build of this
                // code takes: Zig refuses the index where it would.
                if (one == .reflected) {
                    try mapped.append(self.gpa, (try self.reflectedElement(one.reflected, tree, index_node)) orelse continue);
                } else try mapped.append(self.gpa, try self.elementOf(one, tree, index_node));
            }
            // No function of the choice has the parameter: Zig compiles this code in no build.
            if (mapped.items.len == 0) return .{ .unknown = .absent };
            return self.choose(mapped.items);
        },
        // A tuple's element: the one a number names, or, for an index known only as the
        // program compiles (an `inline for`'s), one of a literal's parts.
        .reified => |built| return self.instance(built.fields.*),
        .literal, .instance => {
            if (tree.nodeTag(index_node) == .number_literal) {
                const position = std.fmt.parseInt(usize, tree.tokenSlice(tree.nodeMainToken(index_node)), 0) catch return .{ .unknown = .unsupported };
                return self.destructuredAt(base, position);
            }
            if (base == .instance) return .{ .unknown = .comptime_dependent };
            const parts = try self.literalParts(base.literal);
            if (parts.len == 0) return .{ .unknown = .unsupported };
            return self.choose(parts);
        },
        else => return self.indexed(base, {}),
    }
}

/// A field of reflected information: the kind of type it describes, then its parts.
fn reflectedMember(self: *Facts, r: Reflected, name: []const u8) ResolveError!Value {
    const unsupported: Value = .{ .unknown = .unsupported };
    switch (r.at) {
        .info => {
            // A vector reads as an array of its lanes (`@Vector`), its child an element.
            const kinds = .{ .{ "pointer", .pointer }, .{ "optional", .optional }, .{ "array", .array }, .{ "vector", .array }, .{ "error_union", .error_union }, .{ "fn", .function }, .{ "struct", .structure }, .{ "union", .tagged }, .{ "enum", .enumeration } };
            inline for (kinds) |kind| if (std.mem.eql(u8, name, kind[0])) return .{ .reflected = .{ .of = r.of, .at = kind[1] } };
            // A kind whose information holds no type (an integer's signedness and bits, an
            // error set's names) is the value `std.builtin.Type` declares for it, whatever type
            // it describes: `@typeInfo(E).error_set.error_names` is `?[]const [:0]const u8`. A
            // kind holding types (`anyframe`'s child) is a part, whose types are not read.
            inline for (.{ "int", "float", "error_set", "opaque" }) |plain| if (std.mem.eql(u8, name, plain)) {
                const information = try self.stdMember(&.{ "builtin", "Type" });
                if (information == .unknown) return information;
                return self.memberValue(try self.instance(information), name);
            };
            return .{ .reflected = .{ .of = r.of, .at = .part } };
        },
        .pointer => {
            if (std.mem.eql(u8, name, "child")) return self.pointee(r.of.*, {});
            // Its size: one item, many, a slice or a C pointer (`info.size`), as the type says.
            if (std.mem.eql(u8, name, "size")) return .{ .reflected = .{ .of = r.of, .at = .size } };
            return self.reflectedField(r.at, name);
        },
        .optional => return if (std.mem.eql(u8, name, "child")) self.payload(r.of.*, .optional) else self.reflectedField(r.at, name),
        .error_union => return if (std.mem.eql(u8, name, "payload")) self.payload(r.of.*, .error_union) else self.reflectedField(r.at, name),
        .array => return if (std.mem.eql(u8, name, "child")) self.indexed(r.of.*, {}) else self.reflectedField(r.at, name),
        .function => {
            if (!std.mem.eql(u8, name, "param_types") and !std.mem.eql(u8, name, "return_type")) return self.reflectedField(r.at, name);
            const proto = self.prototype(r.of.*) orelse return if (r.of.* == .unknown) r.of.* else unsupported;
            if (std.mem.eql(u8, name, "param_types")) return .{ .reflected = .{ .of = r.of, .at = .params } };
            // `?type`: null for a result that depends on an argument.
            const result = try self.resultOf(proto);
            if (result == .unknown) return result;
            return .{ .optional = try self.boxed(result) };
        },
        // A container's fields' types, the choice of them, as a slice; their names; and an
        // enum's or a tagged union's tag type. A type of another kind is a prong Zig does not
        // analyse for it.
        .structure, .tagged, .enumeration => {
            // Names are strings whatever the type is (a typeless literal's among them).
            if (std.mem.eql(u8, name, "field_names") or std.mem.eql(u8, name, "decl_names")) return try self.pointerTo(try self.pointerTo(.{ .primitive = "u8" }, .slice), .slice);
            const container = self.reflectedContainer(r) orelse return if (r.of.* == .unknown) r.of.* else unsupported;
            if (std.mem.eql(u8, name, "field_types") and r.at != .enumeration) return try self.pointerTo(try self.fieldTypes(container), .slice);
            if (std.mem.eql(u8, name, "field_values") and r.at == .enumeration) return try self.pointerTo(.scalar, .slice);
            if (std.mem.eql(u8, name, "is_tuple") and r.at == .structure) return .scalar;
            if (std.mem.eql(u8, name, "tag_type") and r.at != .structure) return self.tagType(container, r.at == .tagged);
            return self.reflectedField(r.at, name);
        },
        // A pointer's size is a tag, which has no fields.
        .params, .part, .size => return unsupported,
    }
}

/// A field of type information no rule above reads, whatever type it describes: a value of
/// the type `std.builtin.Type` declares it (`@typeInfo(T).pointer.size` a `Type.Pointer.Size`,
/// `.@"struct".layout` a `Type.ContainerLayout`), where the project maps std.
fn reflectedField(self: *Facts, at: @FieldType(Reflected, "at"), name: []const u8) ResolveError!Value {
    const tag: []const u8 = switch (at) {
        .pointer => "pointer",
        .optional => "optional",
        .array => "array",
        .error_union => "error_union",
        .function => "fn",
        .structure => "struct",
        .tagged => "union",
        .enumeration => "enum",
        .info, .params, .part, .size => return .{ .unknown = .unsupported },
    };
    // The information is a `Type` value: its field `tag` holds a value of the kind's own type.
    const kind = try self.memberValue(try self.instance(try self.stdMember(&.{ "builtin", "Type" })), tag);
    if (kind == .unknown) return kind;
    return self.memberValue(kind, name);
}

/// What `info.is_tuple` is on the reading `env` binds, where `node` is one and `info` a
/// struct's type information: whether its fields are unnamed (`struct { u32, u8 }`; Zig refuses
/// a struct with both). Null where it is not a struct's, or the struct is not known.
fn isTuple(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!?bool {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(node) != .field_access) return null;
    const holder, const name = tree.nodeData(node).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(name), "is_tuple")) return null;
    const info = try self.resolveIn(env, file, holder);
    if (info != .reflected or info.reflected.at != .structure) return null;
    // A type function's container writes its fields named or not whatever it is made with.
    const container = self.reflectedContainer(info.reflected) orelse return null;
    const scope_node = self.project.at(container.file).model.scopes[@backingInt(container.scope)].node;
    if (scope_node == .root) return false;
    const held = self.syntaxOf(container.file);
    var buffer: [2]Ast.Node.Index = undefined;
    const full = held.fullContainerDecl(&buffer, scope_node) orelse return null;
    for (full.ast.members) |item| {
        const field = self.project.at(container.file).model.containerField(held, item) orelse continue;
        return field.ast.tuple_like;
    }
    return false;
}

/// Whether `@typeInfo(X) == .tag`, either way round, holds on the reading `env` binds: the
/// kind of type `X` is (`takenProng`'s) is that tag. Null where neither side is so written or
/// `X`'s kind is not known.
fn kindCompared(self: *Facts, env: ?*const Env, file: Project.FileId, left: Ast.Node.Index, right: Ast.Node.Index) ResolveError!?bool {
    const tree = &self.project.at(file).file.tree;
    const info, const tag = if (isTypeInfo(tree, left) and tree.nodeTag(right) == .enum_literal)
        .{ left, right }
    else if (isTypeInfo(tree, right) and tree.nodeTag(left) == .enum_literal)
        .{ right, left }
    else
        return null;
    const subject = try self.resolveIn(env, file, info);
    if (subject != .reflected or subject.reflected.at != .info) return null;
    const kind = (try self.kindOfType(subject.reflected.of.*)) orelse return null;
    return std.mem.eql(u8, kind, try self.memberName(tree.tokenSlice(tree.nodeMainToken(tag))));
}

/// How many `callTruth`s are read one inside another, at most.
const truth_call_limit = 8;

/// What a call to a function returning `bool` gives on the reading `env` binds, where its body
/// decides it as the program compiles (`std.meta.hasFn(T, "jsonParse")`): its statements read
/// in the reading the call makes, each `if` and `switch` there settled by its bindings, up to
/// the `return` taken. Null where a statement it may return past is not settled.
fn callTruth(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!?bool {
    const tree = &self.project.at(file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    _ = tree.fullCall(&buffer, node) orelse return null;
    // Bounded by how many are read one inside another, not by how deep the caller's reading
    // is: a cut answer is unknown and kept by no reading in progress.
    if (self.truth_calls >= truth_call_limit) {
        self.open_met += 1;
        return null;
    }
    self.truth_calls += 1;
    defer self.truth_calls -= 1;
    const read = (try calls.under(self, env, file, node)) orelse return null;
    const decl = switch (read.callee) {
        .function => |d| d,
        else => return null,
    };
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    const held = &self.project.at(decl.file).file.tree;
    // A function's declaration is its prototype, its body the `fn_decl` holding it.
    const whole = if (held.nodeTag(record.node) == .fn_decl) record.node else self.project.at(decl.file).model.parentOf(record.node) orelse return null;
    if (held.nodeTag(whole) != .fn_decl) return null;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = held.fullFnProto(&proto_buffer, record.node) orelse return null;
    const result = proto.ast.return_type.unwrap() orelse return null;
    if (held.nodeTag(result) != .identifier or !std.mem.eql(u8, held.tokenSlice(held.nodeMainToken(result)), "bool")) return null;
    const bound = (try self.readingFrom(file, node, decl, env)) orelse return null;
    return switch (try self.decidedReturn(bound, decl.file, held.nodeData(whole).node_and_node[1], decided_forks)) {
        .returns => |value| value,
        .falls, .unknown => null,
    };
}

/// What a statement read on `env` does as the program compiles: returns a known `bool`, falls
/// through to the next, or is not known to do either.
const Decided = union(enum) { returns: bool, falls, unknown };

/// How many `if`s whose condition the bindings do not settle `decidedReturn` reads both ways of,
/// one inside another: past it, unknown.
const decided_forks = 4;

fn decidedReturn(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index, forks: u8) ResolveError!Decided {
    const tree = &self.project.at(file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, node)) |statements| return self.decidedSequence(env, file, statements, forks);
    if (tree.nodeTag(node) == .@"return") {
        const value = tree.nodeData(node).opt_node.unwrap() orelse return .unknown;
        return if (try self.comptimeTruth(env, file, value)) |known| .{ .returns = known } else .unknown;
    }
    const unsettled: Decided = if (returnsWithin(tree, node)) .unknown else .falls;
    if (tree.fullIf(node)) |branch| {
        if (branch.payload_token != null or branch.error_token != null) return unsettled;
        const taken = (try self.comptimeTruth(env, file, branch.ast.cond_expr)) orelse return unsettled;
        if (taken) return self.decidedReturn(env, file, branch.ast.then_expr, forks);
        return if (branch.ast.else_expr.unwrap()) |otherwise| self.decidedReturn(env, file, otherwise, forks) else .falls;
    }
    if (tree.fullSwitch(node)) |choice| {
        const taken = (try self.takenProng(env, file, choice)) orelse return unsettled;
        // An array may take a vector's prong too: decided only where one is taken.
        if (taken.other != null) return unsettled;
        return self.decidedReturn(env, file, tree.fullSwitchCase(choice.ast.cases[taken.one]).?.ast.target_expr, forks); // unreachable: a switch's cases are cases
    }
    return unsettled;
}

/// `decidedReturn` of statements run in order: the first that does not fall through decides.
/// An `if` whose condition the bindings do not settle is read both ways, each followed by the
/// statements after it where it falls through, and decides where both ways do alike:
/// `if (unsettled) return false;` before a `return false` the bindings reach.
fn decidedSequence(self: *Facts, env: ?*const Env, file: Project.FileId, statements: []const Ast.Node.Index, forks: u8) ResolveError!Decided {
    const tree = &self.project.at(file).file.tree;
    for (statements, 0..) |statement, n| switch (try self.decidedReturn(env, file, statement, forks)) {
        .falls => continue,
        .returns => |value| return .{ .returns = value },
        .unknown => {
            if (forks == 0) return .unknown;
            const branch = tree.fullIf(statement) orelse return .unknown;
            if (branch.payload_token != null or branch.error_token != null) return .unknown;
            if (try self.comptimeTruth(env, file, branch.ast.cond_expr) != null) return .unknown;
            const rest = statements[n + 1 ..];
            const then = try self.decidedThen(env, file, branch.ast.then_expr, rest, forks - 1);
            const otherwise = if (branch.ast.else_expr.unwrap()) |other| try self.decidedThen(env, file, other, rest, forks - 1) else try self.decidedSequence(env, file, rest, forks - 1);
            if (std.meta.eql(then, otherwise)) return then;
            return .unknown;
        },
    };
    return .falls;
}

/// `decidedReturn` of a branch, then of the statements after it where it falls through.
fn decidedThen(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index, rest: []const Ast.Node.Index, forks: u8) ResolveError!Decided {
    return switch (try self.decidedReturn(env, file, node, forks)) {
        .falls => self.decidedSequence(env, file, rest, forks),
        else => |decided| decided,
    };
}

/// Whether `node` holds a `return`.
fn returnsWithin(tree: *const Ast, node: Ast.Node.Index) bool {
    for (tree.firstToken(node)..tree.lastToken(node) + 1) |token| {
        if (tree.tokenTag(@intCast(token)) == .keyword_return) return true;
    }
    return false;
}

/// The container a reflection of a struct, a union or an enum is of, where it is one of
/// that kind.
fn reflectedContainer(self: *const Facts, r: Reflected) ?Container {
    const container = switch (r.of.*) {
        // `@typeInfo` takes a type: a value of one in its place (a field's type read as what it
        // holds) is that type.
        .container, .instance => |c| c,
        else => return null,
    };
    const kind = self.kindOf(container) orelse return null;
    const wanted: std.zig.Token.Tag = switch (r.at) {
        .structure => .keyword_struct,
        .tagged => .keyword_union,
        .enumeration => .keyword_enum,
        else => return null,
    };
    return if (kind == wanted) container else null;
}

/// The keyword a container is declared with; a file is a struct.
pub fn kindOf(self: *const Facts, container: Container) ?std.zig.Token.Tag {
    const node = self.project.at(container.file).model.scopes[@backingInt(container.scope)].node;
    if (node == .root) return .keyword_struct;
    const tree = self.syntaxOf(container.file);
    var buffer: [2]Ast.Node.Index = undefined;
    const decl = tree.fullContainerDecl(&buffer, node) orelse return null;
    return tree.tokenTag(decl.ast.main_token);
}

/// An enum's integer tag type (`enum(u8)`, else one Zig fits to its fields), or a union's
/// optional tag (`union(Kind)`, an enum Zig makes for `union(enum)`, null for a bare union,
/// whose tag nothing here reads). A container a type function made reads its argument with
/// the call's bindings.
fn tagType(self: *Facts, container: Container, tagged: bool) ResolveError!Value {
    const node = self.project.at(container.file).model.scopes[@backingInt(container.scope)].node;
    const tree = self.syntaxOf(container.file);
    var buffer: [2]Ast.Node.Index = undefined;
    const decl = tree.fullContainerDecl(&buffer, node) orelse return .{ .unknown = .unsupported };
    const tag: Value = if (decl.ast.arg.unwrap()) |arg|
        if (container.made_by) |made| try self.substituted(container.file, arg, made) else try self.resolve(container.file, arg)
    else if (!tagged)
        .{ .primitive = "@Int" }
    else if (decl.ast.enum_token != null)
        .{ .primitive = "@Enum" }
    else
        return .{ .unknown = .unsupported };
    if (tag == .unknown or !tagged) return tag;
    return .{ .optional = try self.boxed(tag) };
}

/// `param_types[i]` of a reflected function, `?type` as Zig gives it: the parameter's
/// declared type, null (unknown here) for `anytype` or a type that depends on an argument.
/// Null where the function has no parameter `i`.
fn reflectedElement(self: *Facts, r: Reflected, tree: *const Ast, index_node: Ast.Node.Index) ResolveError!?Value {
    if (r.at != .params) return .{ .unknown = .unsupported };
    const proto = self.prototype(r.of.*) orelse return .{ .unknown = .unsupported };
    if (tree.nodeTag(index_node) != .number_literal) return .{ .unknown = .comptime_dependent };
    const position = std.fmt.parseInt(usize, tree.tokenSlice(tree.nodeMainToken(index_node)), 0) catch return .{ .unknown = .unsupported };
    const target_tree = &self.project.at(proto.file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, proto.node) orelse return .{ .unknown = .unsupported };
    var it = function.iterate(target_tree);
    var at: usize = 0;
    while (it.next()) |param| : (at += 1) {
        if (at != position) continue;
        const type_expr = param.type_expr orelse return .{ .unknown = .comptime_dependent };
        const value = try self.resolve(proto.file, type_expr);
        if (value == .unknown) return value;
        return .{ .optional = try self.boxed(value) };
    }
    return null;
}

/// The prototype a function or a function type is written with.
fn prototype(self: *const Facts, value: Value) ?Key {
    return switch (value) {
        .function => |decl| .{ .file = decl.file, .node = self.project.at(decl.file).model.declarations[@backingInt(decl.index)].node },
        .fn_type => |key| key,
        else => null,
    };
}

/// The result a prototype declares, as a type, `!T` an error union of it.
fn resultOf(self: *Facts, proto: Key) ResolveError!Value {
    const target_tree = &self.project.at(proto.file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, proto.node) orelse return .{ .unknown = .unsupported };
    const result_node = function.ast.return_type.unwrap() orelse return .{ .unknown = .unsupported };
    const result = try self.resolve(proto.file, result_node);
    if (result == .unknown) return result;
    if (Model.inferredErrors(target_tree, result_node)) return .{ .error_union = try self.boxed(result) };
    return result;
}

/// Whether a function takes a parameter only a call settles: `comptime` or `anytype`.
/// Whether the expression `node` names one of `function`'s generic parameters (`comptime`,
/// `anytype` or of type `type`).
fn namesGenericParameter(tree: *const Ast, function: Ast.full.FnProto, node: Ast.Node.Index) bool {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var it = function.iterate(tree);
    while (it.next()) |param| {
        const generic = param.anytype_ellipsis3 != null or
            (if (param.comptime_noalias) |token| tree.tokenTag(token) == .keyword_comptime else false) or
            (if (param.type_expr) |t| tree.nodeTag(t) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(t)), "type") else false);
        if (!generic) continue;
        const name = tree.tokenSlice(param.name_token orelse continue);
        var token = first;
        while (token <= last) : (token += 1) {
            if (tree.tokenTag(token) == .identifier and std.mem.eql(u8, tree.tokenSlice(token), name)) return true;
        }
    }
    return false;
}

fn isGeneric(tree: *const Ast, function: Ast.full.FnProto) bool {
    var it = function.iterate(tree);
    while (it.next()) |param| {
        if (param.anytype_ellipsis3 != null) return true;
        if (param.comptime_noalias) |token| if (tree.tokenTag(token) == .keyword_comptime) return true;
        if (param.type_expr) |t| if (tree.nodeTag(t) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(t)), "type")) return true;
    }
    return false;
}

/// What calling the generic function `decl` returns with its parameters bound to the call's
/// arguments, read in `env` when the call is itself inside a generic being read: the type a
/// type function returns as an expression (`@typeInfo(T).pointer.child`), or a result type
/// written in terms of its parameters. Null when that reading gives nothing known, for the
/// caller's other means.
fn evaluateCall(self: *Facts, env: ?*const Env, file: Project.FileId, call: Ast.full.Call, decl: Decl) ResolveError!?Value {
    const depth = if (env) |e| e.depth +| 1 else 0;
    const nested = if (env) |e| e.nested +| 1 else 0;
    if (nested >= 8) return null;
    const target_tree = &self.project.at(decl.file).file.tree;
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, record.node) orelse return null;
    const result_node = function.ast.return_type.unwrap() orelse return null;
    const returns_type = target_tree.nodeTag(result_node) == .identifier and std.mem.eql(u8, target_tree.tokenSlice(target_tree.nodeMainToken(result_node)), "type");
    // A bare function type: the function its returns give, the same in every instantiation.
    if (bareFunctionType(target_tree, result_node)) return self.returnedFunction(decl, record);
    // A function of no parameter only a call settles is evaluated only for the type it makes.
    if (!isGeneric(target_tree, function) and !returns_type) return null;
    const tree = &self.project.at(file).file.tree;
    var args: std.ArrayList(Value) = .empty;
    var truths: std.ArrayList(?bool) = .empty;
    // The reading this call is made in: a made container's, for its method (`Slice.items`
    // reading `Elem` of `MultiArrayList(Elem)`), else the calling one.
    var outer = self.enclosingReading(env, decl);
    var spelled: std.ArrayList(?Spelled) = .empty;
    var values: std.ArrayList(bool) = .empty;
    // A method called on a value takes that value as its first parameter.
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        const receiver = try self.resolveIn(env, file, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
        const holder: ?Container = switch (receiver) {
            .instance, .container => |c| c,
            .pointer => |p| switch (p.child.*) {
                .instance, .container => |c| c,
                else => null,
            },
            else => null,
        };
        if (holder) |h| if (h.made_by) |made| {
            outer = try self.madeEnv(made);
        };
        const on_value = switch (receiver) {
            .instance => true,
            .pointer => |p| p.child.* == .instance,
            else => false,
        };
        if (on_value) {
            try args.append(self.gpa, receiver);
            try truths.append(self.gpa, null);
            try spelled.append(self.gpa, null);
            try values.append(self.gpa, try self.valueIn(env, file, tree.nodeData(call.ast.fn_expr).node_and_token[0], 0));
        }
    }
    for (call.ast.params) |arg| {
        try args.append(self.gpa, try self.boundArgument(try self.resolveIn(env, file, arg)));
        try truths.append(self.gpa, self.truth(env, file, arg));
        try spelled.append(self.gpa, try self.spelledIn(env, file, arg));
        try values.append(self.gpa, try self.valueIn(env, file, arg, 0));
    }
    const bound = try self.keptReading(.{ .function = decl, .args = args.items, .depth = depth, .nested = nested, .truths = truths.items, .outer = outer, .spelled = spelled.items, .values = values.items });
    const result_tree = target_tree;
    if (returns_type) {
        const returned = finalReturn(result_tree, &self.project.at(decl.file).model, record) orelse return self.everyReturn(bound, decl, record);
        // A container is the template's, which the call makes: read by the existing means. A
        // function returning one of several (`EnumIndexer`, one per kind of enum) has no one
        // template: each it may return, as `everyReturn` reads them.
        var container_buffer: [2]Ast.Node.Index = undefined;
        if (result_tree.fullContainerDecl(&container_buffer, returned) != null) return if (try self.template(decl) != null) null else self.everyReturn(bound, decl, record);
        const value = try self.resolveIn(bound, decl.file, returned);
        return if (value == .unknown) null else value;
    }
    const value = try self.resolveIn(bound, decl.file, result_node);
    if (value == .unknown) return null;
    if (Model.inferredErrors(result_tree, result_node)) return .{ .error_union = try self.boxed(try self.valueOf(value)) };
    return try self.valueOf(value);
}

/// A value of the type `value` is: an instance of a container, also inside an error union or
/// an optional.
fn valueOf(self: *Facts, value: Value) ResolveError!Value {
    return switch (value) {
        .error_union => |inner| .{ .error_union = try self.boxed(try self.valueOf(inner.*)) },
        .optional => |inner| .{ .optional = try self.boxed(try self.valueOf(inner.*)) },
        else => self.instance(value),
    };
}

/// Whether a type function passes its parameter at `position` on changed where a `return`
/// before its final one (`body`'s `last` statement) calls it again: an argument there that is
/// not that same parameter. Null when an earlier `return` gives anything but such a call.
fn recursion(self: *const Facts, decl: Decl, body: Ast.Node.Index, last: Ast.Node.Index, position: usize) ?bool {
    const tree = &self.project.at(decl.file).file.tree;
    const model = &self.project.at(decl.file).model;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&fn_buffer, model.declarations[@backingInt(decl.index)].node) orelse return null;
    var name: ?Ast.TokenIndex = null;
    var count: usize = 0;
    var it = proto.iterate(tree);
    while (it.next()) |param| : (count += 1) {
        const token = param.name_token orelse return null;
        if (count == position) name = token;
    }
    var changed = false;
    const first = tree.firstToken(body);
    const end = tree.nodeMainToken(last);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const early: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(early);
        if (at < first or at >= end) continue;
        const operand = tree.nodeData(early).opt_node.unwrap() orelse return null;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&call_buffer, operand) orelse return null;
        if (tree.nodeTag(call.ast.fn_expr) != .identifier) return null;
        const callee = (model.reference(call.ast.fn_expr) orelse return null).declaration orelse return null;
        if (callee != decl.index or call.ast.params.len != count) return null;
        const own = name orelse continue;
        const arg = call.ast.params[position];
        const same_parameter = tree.nodeTag(arg) == .identifier and if (model.reference(arg)) |ref| if (ref.declaration) |index| model.declarations[@backingInt(index)].token == own else false else false;
        if (!same_parameter) changed = true;
    }
    return changed;
}

/// The operand of a function body's one `return`, its final statement.
fn finalReturn(tree: *const Ast, model: *const Model, record: Model.Declaration) ?Ast.Node.Index {
    var fn_node = record.node;
    if (tree.nodeTag(fn_node) != .fn_decl) fn_node = model.parentOf(fn_node) orelse return null;
    if (tree.nodeTag(fn_node) != .fn_decl) return null;
    const body = tree.nodeData(fn_node).node_and_node[1];
    var body_buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&body_buffer, body) orelse return null;
    if (statements.len == 0 or tree.nodeTag(statements[statements.len - 1]) != .@"return") return null;
    const last = statements[statements.len - 1];
    for (tree.firstToken(body)..tree.nodeMainToken(last)) |token| {
        if (tree.tokenTag(@intCast(token)) == .keyword_return) return null;
    }
    return tree.nodeData(last).opt_node.unwrap();
}

/// Whether `node` is `true`.
fn isTrue(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "true");
}

/// Whether `node` is `undefined`.
fn isUndefined(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "undefined");
}

/// A local array of types, `undefined` where declared, as what is written to its elements in
/// `function`: an array of the choice of them. Unknown where it is used other than by an
/// element, a slice or its length (assigned whole, its address taken or passed), where a
/// write is unseen, or where nothing is written.
fn writtenElements(self: *Facts, env: ?*const Env, file: Project.FileId, index: Model.Declaration.Id, function: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    var elements: std.ArrayList(Value) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        const ref = model.reference(node) orelse continue;
        if (ref.declaration != index) continue;
        const parent = model.parentOf(node) orelse return .{ .unknown = .unsupported };
        switch (tree.nodeTag(parent)) {
            .array_access => {
                if (tree.nodeData(parent).node_and_node[0] != node) return .{ .unknown = .unsupported };
                const above = model.parentOf(parent) orelse continue;
                if (tree.nodeTag(above) == .assign and tree.nodeData(above).node_and_node[0] == parent)
                    try elements.append(self.gpa, try self.resolveIn(env, file, tree.nodeData(above).node_and_node[1]));
            },
            .slice_open, .slice, .slice_sentinel => if (tree.fullSlice(parent).?.ast.sliced != node) return .{ .unknown = .unsupported }, // unreachable: a slice node is a full slice
            .field_access => if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeData(parent).node_and_token[1]), "len")) return .{ .unknown = .unsupported },
            // Its address read by a builtin that builds a type from it, or a loop's input
            // written through its pointer capture.
            .address_of => if (!try self.elementsByAddress(env, file, parent, &elements)) return .{ .unknown = .unsupported },
            else => return .{ .unknown = .unsupported },
        }
    }
    if (elements.items.len == 0) return .{ .unknown = .unsupported };
    return .{ .array = try self.boxed(try self.choose(elements.items)) };
}

/// Whether `address`, the address of an array `writtenElements` reads, is used so that every
/// write through it is seen: an argument of `@Struct`, `@Union` or `@Tuple`, which reads it;
/// or a `for` loop's input whose capture is a pointer, each element written as `capture.* = v`
/// (added to `elements`) and the capture used no other way.
fn elementsByAddress(self: *Facts, env: ?*const Env, file: Project.FileId, address: Ast.Node.Index, elements: *std.ArrayList(Value)) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    const user = model.parentOf(address) orelse return false;
    if (builtinName(tree, user)) |name| {
        for ([_][]const u8{ "@Struct", "@Union", "@Tuple" }) |reads| if (std.mem.eql(u8, name, reads)) return true;
        return false;
    }
    const loop = tree.fullFor(user) orelse return false;
    const position = std.mem.findScalar(Ast.Node.Index, loop.ast.inputs, address) orelse return false;
    const capture = for (model.declarations, 0..) |d, i| {
        if (d.kind != .capture or d.node != user) continue;
        if (Model.capturePosition(tree, loop, d.token) != position) continue;
        if (tree.tokenTag(d.token - 1) != .asterisk) return false;
        break @as(Model.Declaration.Id, @fromBackingInt(@intCast(i)));
    } else return false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const ref = model.reference(node) orelse continue;
        if (ref.declaration != capture) continue;
        const deref = model.parentOf(node) orelse return false;
        if (tree.nodeTag(deref) != .deref) return false;
        const store = model.parentOf(deref) orelse return false;
        if (tree.nodeTag(store) != .assign or tree.nodeData(store).node_and_node[0] != deref) return false;
        try elements.append(self.gpa, try self.resolveIn(env, file, tree.nodeData(store).node_and_node[1]));
    }
    return true;
}

/// The reading of `function` at one `call` in `file`: its parameters bound to the call's
/// arguments, a method called on a value given that value first, each read under `outer`,
/// the reading the call is itself in. A rule walking down a chain of calls binds each in turn
/// and reads what the callee does under it (`resolveBound`): `value.format(w)` in a generic
/// std calls with what the program handed it.
pub fn bind(self: *Facts, file: Project.FileId, call: Ast.full.Call, function: Decl, outer: ?*const Env) ResolveError!*const Env {
    return self.bindTo(file, call.ast.fn_expr, call.ast.params, function, outer);
}

/// The reading of `function` at `call` as Facts.calls reads it (`f(a)`, `x.f(a)`, `T.f(a)`,
/// `@call`'s callee and tuple), under `outer`, the reading the call is itself in: its arguments
/// bound by `bindTo`, which takes a bound receiver from the callee as written. The one way a
/// reading is made of a call: a rule judging a generic's body at each binding reads it under
/// this. Arguments or a receiver not known give no reading, never one of partial arguments.
pub fn bindCall(self: *Facts, call: *const calls.Call, function: Decl, outer: ?*const Env) ResolveError!Binding {
    const args = switch (call.args) {
        .known => |args| args,
        .unknown => |why| return .{ .unknown = why },
    };
    const params = switch (call.receiver) {
        .none => args,
        .bound => args[1..],
        .unknown => |why| return .{ .unknown = why },
    };
    return .{ .reading = try self.bindTo(call.file, call.callee_expr, params, function, outer) };
}

/// A binding's reading (`bindCall`), or why the call binds what is not known.
pub const Binding = union(enum) { reading: *const Env, unknown: Unknown };

/// `bind` of a call written as its callee `fn_expr` and its arguments `params`, a bound
/// receiver not among them: `f(a)`'s, or `@call`'s callee and its tuple's elements.
pub fn bindTo(self: *Facts, file: Project.FileId, fn_expr: Ast.Node.Index, params: []const Ast.Node.Index, function: Decl, outer: ?*const Env) ResolveError!*const Env {
    const tree = &self.project.at(file).file.tree;
    var args: std.ArrayList(Value) = .empty;
    var truths: std.ArrayList(?bool) = .empty;
    var spelled: std.ArrayList(?Spelled) = .empty;
    var values: std.ArrayList(bool) = .empty;
    var reading = self.enclosingReading(outer, function);
    // Whether the arguments stand in the callee's parameter order: a call not through a member,
    // or one whose holder is known to be a value (bound first) or a type (bound to nothing).
    var aligned = tree.nodeTag(fn_expr) != .field_access;
    if (tree.nodeTag(fn_expr) == .field_access) {
        const receiver = try self.resolveIn(outer, file, tree.nodeData(fn_expr).node_and_token[0]);
        aligned = receiver == .container;
        const holder: ?Container = switch (receiver) {
            .instance => |c| c,
            .pointer => |p| if (p.child.* == .instance) p.child.instance else null,
            else => null,
        };
        if (holder) |h| {
            try args.append(self.gpa, receiver);
            try truths.append(self.gpa, null);
            try spelled.append(self.gpa, null);
            try values.append(self.gpa, try self.valueIn(outer, file, tree.nodeData(fn_expr).node_and_token[0], 0));
            if (h.made_by) |made| reading = try self.madeEnv(made);
            aligned = true;
        }
    }
    for (params) |arg| {
        try args.append(self.gpa, try self.boundArgument(try self.resolveIn(outer, file, arg)));
        try truths.append(self.gpa, self.truth(outer, file, arg));
        try spelled.append(self.gpa, try self.spelledIn(outer, file, arg));
        try values.append(self.gpa, try self.valueIn(outer, file, arg, 0));
    }
    const draft: Env = .{ .function = function, .args = args.items, .depth = if (outer) |o| o.depth +| 1 else 0, .nested = if (outer) |o| o.nested else 0, .truths = truths.items, .outer = reading, .spelled = spelled.items, .values = values.items };
    if (!aligned) return self.keptReading(draft);
    // A typed parameter's argument is read in a reading of its own, then given its declared
    // type: what that reading kept is not the one made with it.
    const reading_args = try self.keptReading(.{ .function = function, .args = try self.gpa.dupe(Value, args.items), .depth = draft.depth, .nested = draft.nested, .truths = draft.truths, .outer = draft.outer, .spelled = draft.spelled, .values = draft.values });
    try self.typedArguments(reading_args, function, args.items);
    return self.keptReading(draft);
}

/// A parameter of a declared type holds a value of that type, whatever its argument reads as
/// (`self.getContext(key, undefined)` of std's unmanaged map, whose `ctx: Context` is its
/// instantiation's context; a `[]const u8` given a `*const [5]u8`): each argument of a
/// parameter neither `anytype` nor a type nor `comptime` is a value of the type the parameter
/// declares in `env`, as Zig coerces it. One that may name a function, or a literal whose
/// fields may, says more than its type does (which function a `*const fn` holds) and stays,
/// as does one already of the declared container, whose making it carries (a context made by
/// `AutoContext(u32)`, its declared `Context` read through a chain of type functions). A
/// reading of a function with no generic parameter is then the same whoever calls it.
fn typedArguments(self: *Facts, env: *const Env, function: Decl, args: []Value) ResolveError!void {
    const tree = &self.project.at(function.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, self.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return;
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (position >= args.len) return;
        if (namesFunction(args[position]) or try self.literalNamesFunction(args[position]) or param.anytype_ellipsis3 != null) continue;
        if (param.comptime_noalias) |token| if (tree.tokenTag(token) == .keyword_comptime) continue;
        const type_expr = param.type_expr orelse continue;
        if (tree.nodeTag(type_expr) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(type_expr)), "type")) continue;
        const declared = try self.resolveIn(env, function.file, type_expr);
        if (declared == .unknown) continue;
        const typed = try self.instance(declared);
        if (args[position] != .unknown and sameContainer(args[position], typed)) continue;
        args[position] = typed;
    }
}

/// Whether `value` is an anonymous literal a field or element of which may name a function,
/// itself or in a literal it holds (`.{ .run = worker }`).
fn literalNamesFunction(self: *Facts, value: Value) ResolveError!bool {
    if (value != .literal) return false;
    for (try self.literalParts(value.literal)) |part| if (namesFunction(part) or try self.literalNamesFunction(part)) return true;
    return false;
}

/// `node` in `file` read under `env`, a reading `bind` made: a parameter is its argument, a
/// constant what initializes it, and what is built of them built again.
pub fn resolveBound(self: *Facts, env: *const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    return self.resolveIn(env, file, node);
}

/// What a type function returns where more than its final statement returns: the choice of
/// every type one of its own `return`s gives with the call's bindings (`bit_set.Static`'s
/// `Integer(size)` or `Array(usize, size)`), a superset of the one a build takes. Null where
/// one is a container it declares, which only the template reads, or one does not resolve.
fn everyReturn(self: *Facts, bound: *const Env, decl: Decl, record: Model.Declaration) ResolveError!?Value {
    const tree = &self.project.at(decl.file).file.tree;
    const model = &self.project.at(decl.file).model;
    const returns = try self.ownReturns(decl, record) orelse return null;
    var values: std.ArrayList(Value) = .empty;
    // Each return a container written in place (`EnumIndexer`'s): one the call makes. One
    // that returns another's call besides is read only by its template.
    const written_only = for (returns) |returned| {
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buffer, returned) == null) break false;
    } else true;
    each: for (returns) |returned| {
        // One in a prong of a switch on type information this type does not take.
        var child = returned;
        var parent = model.parentOf(returned);
        while (parent) |p| : ({
            child = p;
            parent = model.parentOf(p);
        }) {
            if (tree.nodeTag(p) == .fn_decl) break;
            const whole = tree.fullSwitch(p) orelse continue;
            const taken = try self.takenProng(bound, decl.file, whole) orelse continue;
            if (!taken.has(std.mem.findScalar(Ast.Node.Index, whole.ast.cases, child) orelse continue)) continue :each;
        }
        var container_buffer: [2]Ast.Node.Index = undefined;
        const value = if (tree.fullContainerDecl(&container_buffer, returned) != null)
            // A container it declares is the template's, the same in every call where it
            // names nothing the function declares (`return struct {};`); of a function with no
            // one template, one the call makes, read with its bindings (`attachMade`).
            if (try self.bindsNothing(decl.file, returned)) try self.resolve(decl.file, returned) else if (written_only and try self.template(decl) == null) (try self.symbolicAt(decl.file, returned)) orelse return null else return null
        else
            try self.resolveIn(bound, decl.file, returned);
        if (value == .unknown) return null;
        try values.append(self.gpa, value);
    }
    if (values.items.len == 0) return null;
    return try self.choose(values.items);
}

/// The values a function's own `return`s give, in its body outside any function nested in it,
/// found once (`type_returns`). Null where one is a bare `return`, which gives no value.
fn ownReturns(self: *Facts, decl: Decl, record: Model.Declaration) ResolveError!?[]const Ast.Node.Index {
    if (self.type_returns.get(decl)) |known| return known;
    const tree = &self.project.at(decl.file).file.tree;
    const model = &self.project.at(decl.file).model;
    var fn_node = record.node;
    if (tree.nodeTag(fn_node) != .fn_decl) fn_node = model.parentOf(fn_node) orelse return null;
    if (tree.nodeTag(fn_node) != .fn_decl) return null;
    const body = tree.nodeData(fn_node).node_and_node[1];
    var list: std.ArrayList(Ast.Node.Index) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < tree.firstToken(body) or token > tree.lastToken(body)) continue;
        // A method's of a container the function returns is the method's own.
        var parent = model.parentOf(node);
        while (parent) |p| : (parent = model.parentOf(p)) if (tree.nodeTag(p) == .fn_decl) break;
        if (parent != fn_node) continue;
        try list.append(self.gpa, tree.nodeData(node).opt_node.unwrap() orelse return null);
    }
    try self.type_returns.put(self.gpa, decl, list.items);
    return list.items;
}

/// Whether a result type is a bare function type (`fn (Context, K) u64`, grouped or not), not a
/// pointer to one.
fn bareFunctionType(tree: *const Ast, node: Ast.Node.Index) bool {
    var at = node;
    while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
    var buffer: [1]Ast.Node.Index = undefined;
    return tree.nodeTag(at) != .fn_decl and tree.fullFnProto(&buffer, at) != null;
}

/// What a function whose result is a bare function type (`fn (Context, K) u64`, which only
/// comptime code returns) gives: the choice of the functions its own `return`s give (std's
/// `getAutoHashFn` returning `struct { fn hash(...) }.hash`). Null where one is no function.
fn returnedFunction(self: *Facts, decl: Decl, record: Model.Declaration) ResolveError!?Value {
    const returns = try self.ownReturns(decl, record) orelse return null;
    if (returns.len == 0) return null;
    const values = try self.gpa.alloc(Value, returns.len);
    for (returns, values) |returned, *value| {
        value.* = try self.resolve(decl.file, returned);
        if (value.* != .function) return null;
    }
    return try self.choose(values);
}

/// The container a type function declares at `node`, as one its calls make (symbolic, made by
/// none until `attachMade` gives it the call).
fn symbolicAt(self: *const Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    for (self.project.at(file).model.scopes, 0..) |scope, s| if (scope.kind == .container and scope.node == node) return .{ .container = .{ .file = file, .scope = @fromBackingInt(@intCast(s)), .symbolic = true } };
    return null;
}

/// `value`, a call's, with each container the call makes (symbolic, made by none) made by it.
fn attachMade(self: *Facts, value: Value, made: Made) ResolveError!Value {
    switch (value) {
        .container => |c| if (c.symbolic and c.made_by == null) {
            var out = c;
            out.made_by = try self.making(made);
            return .{ .container = out };
        },
        .alternatives => |each| {
            const mapped = try self.gpa.alloc(Value, each.len);
            for (each, mapped) |one, *out| out.* = try self.attachMade(one, made);
            return .{ .alternatives = mapped };
        },
        else => {},
    }
    return value;
}

/// Whether `node` reads the same in every reading: each name it uses is declared in it or
/// outside every function (a parameter, a local, a capture or a constant of a type function's
/// container is a reading's to bind), and it asks no `@This()` (a type function's container
/// is the one its reading makes). By what each name refers to, kept per node.
fn bindsNothing(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    const memory = try self.memo(Unbound);
    const key: Key = .{ .file = file, .node = node };
    if (memory.nodes.get(key)) |known_answer| return known_answer;
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    const named = try self.referencesByToken(file);
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    const answer = for (first..last + 1) |t| {
        const token: Ast.TokenIndex = @intCast(t);
        if (tree.tokenTag(token) == .builtin and std.mem.eql(u8, tree.tokenSlice(token), "@This")) break false;
        const reference = named[t] orelse continue;
        const index = model.references[@backingInt(reference)].declaration orelse continue;
        const record = model.declarations[@backingInt(index)];
        if (record.token >= first and record.token <= last) continue;
        if (inFunction(model, record.scope)) break false;
    } else true;
    try memory.nodes.put(self.gpa, key, answer);
    return answer;
}

const Unbound = struct {
    nodes: std.AutoHashMapUnmanaged(Key, bool) = .empty,
    files: std.AutoHashMapUnmanaged(Project.FileId, []const ?Model.Reference.Id) = .empty,
};

/// Each token's reference in `file`'s model, where it is one: indexed once per file.
fn referencesByToken(self: *Facts, file: Project.FileId) ResolveError![]const ?Model.Reference.Id {
    const memory = try self.memo(Unbound);
    const entry = try memory.files.getOrPut(self.gpa, file);
    if (entry.found_existing) return entry.value_ptr.*;
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    const named = try self.gpa.alloc(?Model.Reference.Id, tree.tokens.len);
    @memset(named, null);
    for (model.references, 0..) |reference, i| named[reference.token] = @fromBackingInt(@intCast(i));
    entry.value_ptr.* = named;
    return named;
}

/// Whether a declaration of scope `scope` is inside a function.
fn inFunction(model: *const Model, scope: Model.Scope.Id) bool {
    var at: ?Model.Scope.Id = scope;
    while (at) |each| : (at = model.scopes[@backingInt(each)].parent) {
        if (model.scopes[@backingInt(each)].kind == .function) return true;
    }
    return false;
}

/// `node` read with `env`'s bindings: a parameter of the function being read is its argument,
/// a constant declared in its body is what initialises it, and what is built from them is
/// built again; anything else resolves as it does everywhere.
fn resolveIn(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const e = env orelse return self.resolve(file, node);
    if (file != e.function.file) return self.resolve(file, node);
    // What names nothing a reading binds reads as it does with none, kept once for every one.
    if (try self.bindsNothing(file, node)) return self.resolve(file, node);
    // A reading is made once and never changed (`bind`), so what a node gives in it is kept by
    // its address, as `resolve` keeps what a node gives with no binding: a chain of calls
    // (`x.sqn(..).mul(..)`) reads each receiver once, not again at each call it holds.
    const key: Bound = .{ .env = e, .settled = .{ .key = .{ .file = file, .node = node }, .assumed = self.assumed } };
    if (self.bound.get(key)) |value| return value;
    if (self.remaining == 0) return self.spent();
    self.remaining -= 1;
    const wide = self.wide;
    const value = try self.readBound(e, file, node);
    // Read with none left, a part of it may have come back unknown(budget): it is not kept;
    // nor what an answer wider than the built analysis gives was read on (`wideSince`).
    if (self.remaining != 0 and !self.wideSince(wide)) try self.bound.put(self.gpa, key, value);
    return value;
}

/// What `node` gives in the reading `e` (`resolveIn`), read once per reading.
fn readBound(self: *Facts, e: *const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const env: ?*const Env = e;
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    switch (tree.nodeTag(node)) {
        .identifier => {
            const ref = model.reference(node) orelse return self.resolve(file, node);
            const index = ref.declaration orelse return self.resolve(file, node);
            const record = model.declarations[@backingInt(index)];
            const function_scope = self.scopeNode(e.function);
            if (record.kind == .parameter) {
                // This call's parameter, or one of a reading it is made in.
                var at: ?*const Env = e;
                while (at) |reading| : (at = reading.outer) {
                    if (reading.function.file != file or model.scopes[@backingInt(record.scope)].node != self.scopeNode(reading.function)) continue;
                    if (self.parameterPosition(file, reading.function, record.token)) |position| {
                        if (position < reading.args.len) return reading.args[position];
                    }
                    return .{ .unknown = .comptime_dependent };
                }
            }
            // A constant of this reading's function, or of one it is made in (`Elem` in
            // `MultiArrayList(T)`'s container, read by its `Slice.items`), read with that one.
            var reading: ?*const Env = e;
            const declared_in = while (reading) |r| : (reading = r.outer) {
                if (r.function.file == file and self.enclosed(file, record.scope, self.scopeNode(r.function))) break r;
            } else null;
            if (record.kind == .variable) if (declared_in) |r| {
                const env_here: ?*const Env = r;
                const variable = tree.fullVarDecl(record.node) orelse return self.resolve(file, node);
                if (variable.ast.type_node.unwrap()) |t| {
                    const type_value = try self.resolveIn(env_here, file, t);
                    if (!holdsTypes(type_value)) return self.instance(type_value);
                    // An array of types written element by element (`types[len] = ?F;`).
                    if (type_value == .array and tree.tokenTag(variable.ast.mut_token) == .keyword_var) if (variable.ast.init_node.unwrap()) |init| if (isUndefined(tree, init))
                        return self.writtenElements(env_here, file, index, self.scopeNode(r.function));
                }
                if (variable.ast.init_node.unwrap()) |init| return self.resolveIn(env_here, file, init);
            };
            // A capture of the function's own: what it captures, read with the call's bindings.
            if (record.kind == .capture and self.enclosed(file, record.scope, function_scope)) return self.captured(env, .{ .file = file, .index = index });
            return self.resolve(file, node);
        },
        .field_access => {
            const data = tree.nodeData(node).node_and_token;
            return self.memberValue(try self.resolveIn(env, file, data[0]), try self.memberName(tree.tokenSlice(data[1])));
        },
        .unwrap_optional => return self.payload(try self.resolveIn(env, file, tree.nodeData(node).node_and_token[0]), .optional),
        .@"try" => return self.payload(try self.resolveIn(env, file, tree.nodeData(node).node), .error_union),
        .grouped_expression => return self.resolveIn(env, file, tree.nodeData(node).node_and_token[0]),
        .@"comptime", .@"nosuspend" => return self.resolveIn(env, file, tree.nodeData(node).node),
        .optional_type => return .{ .optional = try self.boxed(try self.resolveIn(env, file, tree.nodeData(node).node)) },
        .error_union => return .{ .error_union = try self.boxed(try self.resolveIn(env, file, tree.nodeData(node).node_and_node[1])) },
        .@"switch", .switch_comma, .@"if" => if (try self.branches(env, file, node)) |value| return value,
        .block, .block_semicolon, .block_two, .block_two_semicolon => if (try self.breaks(env, file, node)) |value| return value,
        .array_access => {
            const operands = tree.nodeData(node).node_and_node;
            const base = try self.resolveIn(env, file, operands[0]);
            // A literal indexed by a parameter the call binds to a number: that part.
            if (base == .literal) if (self.boundNumber(env, file, operands[1])) |position| return self.destructuredAt(base, position);
            return self.elementOf(base, tree, operands[1]);
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return self.builtin(env, file, node),
        .address_of => return self.pointerTo(try self.resolveIn(env, file, tree.nodeData(node).node), .one),
        .deref => return self.pointee(try self.resolveIn(env, file, tree.nodeData(node).node), {}),
        .slice_open, .slice, .slice_sentinel => return self.sliced(try self.resolveIn(env, file, tree.fullSlice(node).?.ast.sliced), {}), // unreachable: a slice node is a full slice
        .@"catch", .@"orelse" => return self.unwrapped(env, file, node),
        .call_one, .call_one_comma, .call, .call_comma => {
            var call_buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&call_buffer, node).?;
            const callee = try self.resolveIn(env, file, call.ast.fn_expr);
            if (callee != .function) return self.callResult(callee, {});
            if (try self.evaluateCall(env, file, call, callee.function)) |value| return self.attachMade(value, .{ .function = callee.function, .file = file, .call = node, .env = e, .assumed = self.assumed });
            var result = try self.callResult(callee, {});
            // A container a type function makes here is made with this reading's bindings.
            if (result == .container and result.container.symbolic) {
                result.container.made_by = try self.making(.{ .function = callee.function, .file = file, .call = node, .env = e, .assumed = self.assumed });
            }
            return result;
        },
        else => {},
    }
    if (tree.fullPtrType(node)) |ptr| return try self.pointerTo(try self.resolveIn(env, file, ptr.ast.child_type), ptr.size);
    if (tree.fullArrayType(node)) |array| return .{ .array = try self.boxed(try self.resolveIn(env, file, array.ast.elem_type)) };
    // A container the reading's function declares in its body, naming what the reading binds
    // (`const Instance = struct { fn_args: Args }`): this reading's, as Zig makes one per
    // instantiation, its names read with these bindings.
    var container_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_buffer, node) != null) if (try self.symbolicAt(file, node)) |found| {
        if (self.enclosed(file, found.container.scope, self.scopeNode(e.function))) {
            const made = try self.gpa.create(Made);
            made.* = .{ .function = e.function, .file = file, .call = node, .reading = e, .assumed = self.assumed, .bound = e };
            var out = found.container;
            out.made_by = made;
            return .{ .container = out };
        }
    };
    return self.resolve(file, node);
}

/// Whether `scope` is in the function at `function_node` or in a function declared in it, as a
/// container's that the function returns or calls: what its body reads of the function's comptime
/// parameters is fixed by each binding of the function.
fn enclosed(self: *const Facts, file: Project.FileId, scope: Model.Scope.Id, function_node: Ast.Node.Index) bool {
    const scopes = self.project.at(file).model.scopes;
    var at: ?Model.Scope.Id = scope;
    while (at) |s| : (at = scopes[@backingInt(s)].parent) {
        if (scopes[@backingInt(s)].kind == .function and scopes[@backingInt(s)].node == function_node) return true;
    }
    return false;
}

/// The reading on `chain` (a reading, then each one it is made in) whose function encloses
/// `function`: the nearest, none where none does. Only it binds a name `function` reads
/// beyond its own parameters (`resolveIn`'s parameter and constant walks, `nameIn`); a
/// calling reading that does not enclose it binds none, and kept as its outer one would make
/// a reading of it per chain of callers.
fn enclosingReading(self: *const Facts, chain: ?*const Env, function: Decl) ?*const Env {
    const scope = self.project.at(function.file).model.declarations[@backingInt(function.index)].scope;
    var at = chain;
    while (at) |reading| : (at = reading.outer) {
        if (reading.function.file == function.file and self.enclosed(function.file, scope, self.scopeNode(reading.function))) return reading;
    }
    return null;
}

/// The number a parameter named at `node` is bound to by `env`'s call, written there as a
/// literal (`Pick(1)`).
fn boundNumber(self: *const Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ?usize {
    const e = env orelse return null;
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(node) != .identifier) return null;
    const model = &self.project.at(file).model;
    const index = (model.reference(node) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(index)];
    if (record.kind != .parameter or file != e.function.file or model.scopes[@backingInt(record.scope)].node != self.scopeNode(e.function)) return null;
    const position = self.parameterPosition(file, e.function, record.token) orelse return null;
    if (position >= e.spelled.len) return null;
    const spelled = e.spelled[position] orelse return null;
    return if (spelled == .number) spelled.number else null;
}

/// What the argument at `node` spells, read in `env` (`Spelled`): a number literal's value, a
/// name `nameIn` reads, or nothing.
fn spelledIn(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Spelled {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(node) == .number_literal) {
        const number = std.fmt.parseInt(usize, tree.tokenSlice(tree.nodeMainToken(node)), 0) catch return null;
        return .{ .number = number };
    }
    return .{ .name = (try self.nameIn(env, file, node, 0)) orelse return null };
}

/// The parameter at `position` in `function`'s list; null past its end, or for one with no
/// name.
pub fn parameterAt(self: *const Facts, function: Decl, position: usize) ?Decl {
    const tree = &self.project.at(function.file).file.tree;
    const model = &self.project.at(function.file).model;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&fn_buffer, model.declarations[@backingInt(function.index)].node) orelse return null;
    var it = proto.iterate(tree);
    var at: usize = 0;
    const token = while (it.next()) |param| : (at += 1) {
        if (at == position) break param.name_token orelse return null;
    } else return null;
    for (model.declarations, 0..) |record, d| if (record.kind == .parameter and record.token == token) return .{ .file = function.file, .index = @fromBackingInt(@intCast(d)) };
    return null;
}

/// The position of the parameter named by `token` in `function`'s list.
fn parameterPosition(self: *const Facts, file: Project.FileId, function: Decl, token: Ast.TokenIndex) ?usize {
    const tree = &self.project.at(file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&fn_buffer, self.project.at(file).model.declarations[@backingInt(function.index)].node) orelse return null;
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) if (param.name_token == token) return position;
    return null;
}

/// The function declaring parameter `decl`, and its position, when it is `anytype` or a
/// `comptime` type: a parameter only its calls settle.
fn settledByCalls(self: *Facts, decl: Decl) ResolveError!?usize {
    const model = &self.project.at(decl.file).model;
    const tree = &self.project.at(decl.file).file.tree;
    const record = model.declarations[@backingInt(decl.index)];
    const function = self.functionOf(decl) orelse return null;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&fn_buffer, model.declarations[@backingInt(function.index)].node) orelse return null;
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (param.name_token != record.token) continue;
        if (param.anytype_ellipsis3 != null) return position;
        // A `type` parameter is comptime, written so or not.
        const type_expr = param.type_expr orelse return null;
        if (tree.nodeTag(type_expr) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(type_expr)), "type")) return position;
        return null;
    }
    return null;
}

/// The type expression a function's parameter is declared with (in its own file), or null for
/// `anytype` or a parameter of no function the file declares.
/// Whether the place `node`'s value goes is written a pointer to `const`: a declaration's
/// written type, or the parameter a call passes it to (each the call may reach), through a
/// grouping. A cast into it reads the memory it points at, never writes it.
pub fn constPointerPlace(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    const parent = model.parentOf(node) orelse return false;
    if (tree.nodeTag(parent) == .grouped_expression) return self.constPointerPlace(file, parent);
    if (tree.fullVarDecl(parent)) |variable| {
        if (variable.ast.init_node.unwrap() != node) return false;
        return constPointerType(tree, variable.ast.type_node.unwrap() orelse return false);
    }
    const call = (try calls.at(self, file, parent)) orelse return false;
    if (call.args != .known) return false;
    const position = std.mem.findScalar(Ast.Node.Index, call.args.known, node) orelse return false;
    const one: [1]Decl = switch (call.callee) {
        .function => |decl| .{decl},
        else => undefined,
    };
    const each: []const Decl = switch (call.callee) {
        .function => &one,
        .choice => |choice| choice,
        .any => return false,
    };
    for (each) |decl| {
        const target = &self.project.at(decl.file).file.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = target.fullFnProto(&buffer, self.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return false;
        var it = proto.iterate(target);
        var at: usize = 0;
        const kind = while (it.next()) |param| : (at += 1) {
            if (at == position) break param.type_expr orelse return false;
        } else return false;
        if (!constPointerType(target, kind)) return false;
    }
    return true;
}

/// Whether `node` writes a pointer or a slice to `const`.
fn constPointerType(tree: *const Ast, node: Ast.Node.Index) bool {
    const pointer = tree.fullPtrType(node) orelse return false;
    return pointer.const_token != null;
}

pub fn parameterTypeNode(self: *const Facts, parameter: Decl) ?Ast.Node.Index {
    const model = &self.project.at(parameter.file).model;
    const tree = &self.project.at(parameter.file).file.tree;
    const function = self.functionOf(parameter) orelse return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(function.index)].node) orelse return null;
    var it = proto.iterate(tree);
    while (it.next()) |param| {
        if (param.name_token != model.declarations[@backingInt(parameter.index)].token) continue;
        return param.type_expr;
    }
    return null;
}

fn functionOf(self: *const Facts, parameter: Decl) ?Decl {
    const model = &self.project.at(parameter.file).model;
    const scope = model.scopes[@backingInt(model.declarations[@backingInt(parameter.index)].scope)];
    if (scope.kind != .function) return null;
    for (model.declarations, 0..) |d, i| {
        if (d.kind != .function) continue;
        const candidate: Decl = .{ .file = parameter.file, .index = @fromBackingInt(@intCast(i)) };
        if (self.scopeNode(candidate) == scope.node) return candidate;
    }
    return null;
}

/// Whether the container `scope` is declared in a function's body (a type function's `struct`,
/// a generic's local type), not at a file's or another container's level alone.
fn declaredInFunction(model: *const Model, scope: Model.Scope.Id) bool {
    var at = model.scopes[@backingInt(scope)].parent;
    while (at) |up| : (at = model.scopes[@backingInt(up)].parent) switch (model.scopes[@backingInt(up)].kind) {
        .function => return true,
        .container, .file => return false,
        else => {},
    };
    return false;
}

/// The node a function's scope is recorded at: its declaration with a body, else its prototype.
fn scopeNode(self: *const Facts, function: Decl) Ast.Node.Index {
    const model = &self.project.at(function.file).model;
    const proto = model.declarations[@backingInt(function.index)].node;
    const tree = &self.project.at(function.file).file.tree;
    if (model.parentOf(proto)) |parent| if (tree.nodeTag(parent) == .fn_decl) return parent;
    return proto;
}

/// A generic parameter's value as the project's own calls bind it: the union of their
/// arguments at its position, when every use of the function is a call within the project
/// and its consumers cannot call it by name. Anything else stays unknown.
fn boundByCallers(self: *Facts, parameter: Decl, position: usize) ResolveError!Value {
    const function = self.functionOf(parameter) orelse return .{ .unknown = .comptime_dependent };
    const found = (try self.callArguments(function, position)) orelse return .{ .unknown = .generic };
    // A call that passes something from a module the build does not have is not compiled.
    var values: std.ArrayList(Value) = .empty;
    for (found) |value| if (!absent(value)) try values.append(self.gpa, value);
    // No call the build compiles binds it: whatever binding is made decides.
    if (values.items.len == 0) return .{ .unknown = .generic };
    return self.choose(values.items);
}

/// Whether a value comes from a module the build does not have, itself or through what
/// wraps it.
fn absent(value: Value) bool {
    return switch (value) {
        .unknown => |why| why == .absent,
        .pointer => |inner| absent(inner.child.*),
        .array, .optional, .error_union => |inner| absent(inner.*),
        else => false,
    };
}

/// The arguments every call of `function` in the project passes at `position`, or null where
/// code outside the program may call it (`escapes`), or a call passes fewer.
fn callArguments(self: *Facts, function: Decl, position: usize) ResolveError!?[]const Value {
    const sites = (try self.callSites(function)) orelse return null;
    var values: std.ArrayList(Value) = .empty;
    for (sites) |site| {
        if (position < site.receiver) {
            try values.append(self.gpa, try self.resolve(site.file, site.holder));
            continue;
        }
        if (position - site.receiver >= site.params.len) return null;
        try values.append(self.gpa, try self.resolve(site.file, site.params[position - site.receiver]));
    }
    return values.items;
}

/// What a declaration of a function holds on each call of the function, read with that call's
/// bindings (`var lock: std.meta.Child(T) = .init` on `bump(Locks, …)`): a local's written
/// type's instance, else its initializer's value; a parameter's type's instance; the function's
/// own result. A declaration known only as the program compiles is judged so, never by its
/// function's signature. Null where a call of the function is none the program shows
/// (`escapes`), or the declaration is none of those.
pub fn atBindings(self: *Facts, decl: Decl) ResolveError!?[]const Value {
    if (self.at_bindings.get(decl)) |found| return found;
    const found = try self.readAtBindings(decl);
    try self.at_bindings.put(self.gpa, decl, found);
    return found;
}

/// How `atBindings` and `atCall` read a declaration: the function it is in, the node read with a
/// call's bindings, and what of that node's value it holds.
const BindingRead = struct { function: Decl, node: Ast.Node.Index, read: enum { instance, value, result } };

fn bindingRead(self: *Facts, decl: Decl) ?BindingRead {
    const model = &self.project.at(decl.file).model;
    const tree = &self.project.at(decl.file).file.tree;
    const record = model.declarations[@backingInt(decl.index)];
    return switch (record.kind) {
        .variable => blk: {
            const variable = tree.fullVarDecl(record.node) orelse return null;
            const body = self.innermostFunction(decl.file, record.scope) orelse return null;
            const function = for (model.declarations, 0..) |d, i| {
                const candidate: Decl = .{ .file = decl.file, .index = @fromBackingInt(@intCast(i)) };
                if (d.kind == .function and self.scopeNode(candidate) == body) break candidate;
            } else return null;
            if (variable.ast.type_node.unwrap()) |t| break :blk .{ .function = function, .node = t, .read = .instance };
            break :blk .{ .function = function, .node = variable.ast.init_node.unwrap() orelse return null, .read = .value };
        },
        .parameter => .{ .function = self.functionOf(decl) orelse return null, .node = record.node, .read = .instance },
        .function => blk: {
            var buffer: [1]Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, record.node) orelse return null;
            break :blk .{ .function = decl, .node = proto.ast.return_type.unwrap() orelse return null, .read = .result };
        },
        else => null,
    };
}

/// What `how` reads with the bindings `args` give its function.
fn readWith(self: *Facts, decl: Decl, how: BindingRead, args: []const Value) ResolveError!Value {
    const tree = &self.project.at(decl.file).file.tree;
    const env = try self.gpa.create(Env);
    env.* = .{ .function = how.function, .args = args, .depth = 0 };
    const found = try self.resolveIn(env, decl.file, how.node);
    return switch (how.read) {
        .value => found,
        .instance => try self.instance(found),
        // `!T`: an error union whose error set the body infers, as `callResult` reads it.
        .result => if (Model.inferredErrors(tree, how.node) and found != .unknown) .{ .error_union = try self.boxed(try self.instance(found)) } else try self.instance(found),
    };
}

fn readAtBindings(self: *Facts, decl: Decl) ResolveError!?[]const Value {
    const how = self.bindingRead(decl) orelse return null;
    const sites = (try self.callSites(how.function)) orelse return null;
    var values: std.ArrayList(Value) = .empty;
    for (sites) |site| {
        var args: std.ArrayList(Value) = .empty;
        if (site.receiver != 0) try args.append(self.gpa, try self.resolve(site.file, site.holder));
        for (site.params) |arg| try args.append(self.gpa, try self.resolve(site.file, arg));
        try values.append(self.gpa, try self.readWith(decl, how, args.items));
    }
    return values.items;
}

/// What a declaration of a function holds on the one call `call` (`calls.at`) of it, read with
/// that call's bindings as `atBindings` reads each: null where the declaration is none it reads,
/// or the call's arguments are not known.
pub fn atCall(self: *Facts, decl: Decl, call: calls.Call) ResolveError!?Value {
    const how = self.bindingRead(decl) orelse return null;
    const given = switch (call.args) {
        .known => |each| each,
        .unknown => return null,
    };
    var args: std.ArrayList(Value) = .empty;
    for (given) |arg| try args.append(self.gpa, try self.resolve(call.file, arg));
    return try self.readWith(decl, how, args.items);
}

/// Whether code outside the program's own calls may call `function`, with values no call of
/// the program's shows: a consumer by name, as any public function may be (a run need not hold
/// a file importing the package), std's or a known library's code
/// through a member of a value the program hands it (a context's `hash`), or anyone given the
/// function itself as a value (`std.mem.sort(T, items, {}, less)`, `Thread.spawn(.{}, worker,
/// …)`). Each of the function's parameters may then hold anything.
pub fn escapes(self: *Facts, function: Decl) ResolveError!bool {
    return (try self.callSites(function)) == null;
}

/// Whether std's or a known library's code, or anyone given the function as a value, may call
/// `function`: what `escapes` reads but a consumer calling it by its exported name, which hands
/// it the consumer's own values, as the program's own callers do.
pub fn handedOut(self: *Facts, function: Decl) ResolveError!bool {
    return try self.namedCalls(function) == null;
}

/// One call of a function the program makes: its arguments, after the receiver a method call
/// on a value passes first (`holder`).
pub const CallSite = struct { file: Project.FileId, params: []const Ast.Node.Index, receiver: usize, holder: Ast.Node.Index };
const CallSites = struct { map: std.AutoHashMapUnmanaged(Decl, ?[]const CallSite) = .empty };

/// Every call of `function` the program makes, or null where it `escapes`. Read once.
pub fn callSites(self: *Facts, function: Decl) ResolveError!?[]const CallSite {
    const read = try self.memo(CallSites);
    if (read.map.get(function)) |known_sites| return known_sites;
    const found = try self.scanCallSites(function, .consumers);
    try read.map.put(self.gpa, function, found);
    return found;
}

const NamedSites = struct { map: std.AutoHashMapUnmanaged(Decl, ?usize) = .empty };

/// How many calls of `function` the program makes where every binding of it is a call by its
/// name that a run judges: the program's own, or a consumer's in the consumer's run, which
/// reads this package too. Null where it is used otherwise (handed on as a value, called on a
/// holder that does not resolve) or where std's or aegis's code may call a member of its name
/// on a value the program hands it (`HashMap`'s `ctx.hash(key)`): a binding there is no call a
/// rule sees. Read once.
fn namedCalls(self: *Facts, function: Decl) ResolveError!?usize {
    const read = try self.memo(NamedSites);
    if (read.map.get(function)) |known| return known;
    const found: ?usize = if (try self.scanCallSites(function, .program)) |sites| sites.len else null;
    try read.map.put(self.gpa, function, found);
    return found;
}

/// Whether every binding of `function` is a call a run judges (`namedCalls`).
pub fn judgedAtBindings(self: *Facts, function: Decl) ResolveError!bool {
    return try self.namedCalls(function) != null;
}

/// Whether compiled code in the run binds the generic `function` (main's ruling, 2026-11-04):
/// a call of it by name in a function that is no generic, at a container's level or in a test,
/// or in a generic that is itself bound in the run; a call in a generic nothing compiled binds
/// is compiled nowhere. A generic's body means nothing until it is bound: a rule judges what
/// only a binding decides at each binding, clean at the body where this is true; where it is
/// false the body is undecided (`unbound_generic`), judged at its consumers' bindings, its
/// remedy a test that instantiates it. Null where a binding may be no call a run judges
/// (`judgedAtBindings`): the body stays undecided as the rule reads it.
pub fn boundInRun(self: *Facts, function: Decl) ResolveError!?bool {
    const read = try self.memo(BoundInRun);
    // One being read (a generic that binds itself) binds nothing of its own.
    if (read.map.get(function)) |known| return known orelse false;
    const sites = (try self.scanCallSites(function, .program)) orelse {
        try read.map.put(self.gpa, function, null);
        return null;
    };
    try read.map.put(self.gpa, function, false);
    var bound = false;
    for (sites) |site| {
        const outer = (try self.functionAround(site.file, site.holder)) orelse {
            bound = true;
            break;
        };
        if (!self.hasGenericParameter(outer) or try self.boundInRun(outer) == true) {
            bound = true;
            break;
        }
    }
    try read.map.put(self.gpa, function, bound);
    return bound;
}

/// What a rule writes at a generic's body that `boundInRun` says nothing compiled binds.
pub const unbound_generic = "unbound generic: judged at its consumers' bindings";

/// `boundInRun`'s answers, false while one is being read.
const BoundInRun = struct { map: std.AutoHashMapUnmanaged(Decl, ?bool) = .empty };

/// The function whose body `node` in `file` is in; null at a container's level or in a test.
fn functionAround(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Decl {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) switch (tree.nodeTag(parent)) {
        .fn_decl => {
            const index = (try self.partsOf(file)).declared.get(parent) orelse return null;
            return .{ .file = file, .index = index };
        },
        .test_decl => return null,
        else => {},
    };
    return null;
}

/// `callers` says whether a consumer calling a public function by its name is a caller no
/// scan of the program sees (`consumers`), or one judged in the consumer's own run (`program`).
fn scanCallSites(self: *Facts, function: Decl, callers: enum { consumers, program }) ResolveError!?[]const CallSite {
    const model = &self.project.at(function.file).model;
    const record = model.declarations[@backingInt(function.index)];
    if (callers == .consumers and record.public) return null;
    const name_token = record.token;
    const name = self.project.at(function.file).file.tree.tokenSlice(name_token);
    // std's or aegis's code may call it on a value the program hands it: callers no scan of the
    // program sees.
    if (record.public and try self.calledOutside(name)) return null;
    var sites: std.ArrayList(CallSite) = .empty;
    for (self.project.sources) |*source| {
        const file = source.file;
        const file_model = &source.model;
        if (file.status != .parsed) continue;
        // A private function is used in its own file only; a file outside the package
        // reaches it only through a module's exported names, which this one is not among.
        const id = source.id;
        const own = id == function.file;
        if (!record.public and !own) continue;
        if (!try self.program(source.id)) continue;
        const tree = &file.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const names_it = switch (tag) {
                .identifier => blk: {
                    const ref = file_model.reference(node) orelse break :blk false;
                    break :blk own and ref.declaration != null and ref.declaration.? == function.index;
                },
                .field_access => std.mem.eql(u8, tree.tokenSlice(tree.nodeData(node).node_and_token[1]), name),
                else => false,
            };
            if (!names_it) continue;
            // The declaration's own name token is no use of it, nor an enum's field of that name.
            if (tag == .identifier and tree.nodeMainToken(node) == name_token and own) continue;
            if (tag == .identifier and file_model.tagName(tree, node)) continue;
            const parent = file_model.node_parents[i] orelse return null;
            // `@TypeOf(f)` asks its type: no use of it that passes it on.
            if (isTypeQuery(tree, parent)) continue;
            var receiver: usize = 0;
            // Whether this use calls what it names. A value's method is reached only by a call:
            // Zig has no bound methods, so a value's member used otherwise is its field.
            var callee_buffer: [1]Ast.Node.Index = undefined;
            var tuple_buffer: [2]Ast.Node.Index = undefined;
            const callee = callParams(tree, parent, node, &callee_buffer, &tuple_buffer) != null;
            // A member written to or read as a number is a field: a function is neither.
            if (tag == .field_access and !callee and fieldUse(tree, parent, node)) continue;
            // A member of a value the program holds at run time, not called, is a field: no
            // need to resolve the value, which may itself be bound by this function's calls.
            if (tag == .field_access and !callee and try self.runtimeValue(id, tree.nodeData(node).node_and_token[0], 0)) continue;
            if (tag == .field_access) {
                const target = try self.resolve(id, tree.nodeData(node).node_and_token[0]);
                // What the name is a member of: each alternative that can have members. One
                // that does not resolve may be this function's container.
                const parts = try self.holders(target);
                var calls_it = false;
                for (parts) |part| {
                    const container: Container, const on_value = switch (part) {
                        .container => |c| .{ c, false },
                        .instance => |c| .{ c, true },
                        // A pointer is a value: its method takes it as the first parameter.
                        .pointer => |pointed| switch (pointed.child.*) {
                            .instance, .container => |c| .{ c, true },
                            .unknown => if (!callee or try self.cannotBe(tree, parent, node, function)) continue else return null,
                            else => continue,
                        },
                        // A path of declarations from a module's root reaches only what the
                        // module exports by name, which this function's container is not.
                        .unknown => if (try self.cannotBe(tree, parent, node, function) or self.throughModule(id, tree.nodeData(node).node_and_token[0]) or (!callee and try self.runtimeValue(id, tree.nodeData(node).node_and_token[0], 0))) continue else return null,
                        // `void`, a number or an error has no member to call.
                        else => continue,
                    };
                    const found = self.member(container, name) orelse continue;
                    if (!std.meta.eql(found, function)) continue;
                    calls_it = true;
                    if (on_value) receiver = 1;
                }
                if (!calls_it) continue;
            }
            const params = callParams(tree, parent, node, &callee_buffer, &tuple_buffer) orelse return null;
            const holder = if (tag == .field_access) tree.nodeData(node).node_and_token[0] else node;
            try sites.append(self.gpa, .{ .file = id, .params = try self.gpa.dupe(Ast.Node.Index, params), .receiver = receiver, .holder = holder });
        }
    }
    return sites.items;
}

/// Whether code outside the program (std's or a known library's) may call a function named
/// `name` of the program's: a call through a member so spelled, or through `@field` with a name
/// that is so spelled or computed, on a receiver that does not resolve to a container of its own
/// (a generic's type parameter, `anytype`), as `HashMap` calls its context's `hash`. A call in
/// code no compilation of the program analyzes (`analyzedAt`) calls nothing.
fn calledOutside(self: *Facts, name: []const u8) ResolveError!bool {
    const found = try self.memo(OutsideCalls);
    if (!found.built) {
        found.built = true;
        for (self.project.sources) |*source| {
            if (source.file.status != .parsed or try self.program(source.id)) continue;
            // A file no compilation analyzes calls nothing (`fileAnalyzed`): no part of it is
            // read unless the walk entered it.
            if (!try self.fileAnalyzed(source.id)) continue;
            const tree = &source.file.tree;
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                const parent = source.model.node_parents[i] orelse continue;
                var call_buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&call_buffer, parent) orelse continue;
                if (call.ast.fn_expr != node) continue;
                const receiver: Ast.Node.Index, const spelled: []const u8 = switch (tag) {
                    .field_access => .{ tree.nodeData(node).node_and_token[0], tree.tokenSlice(tree.nodeData(node).node_and_token[1]) },
                    .builtin_call_two, .builtin_call_two_comma => blk: {
                        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field")) continue;
                        var buffer: [2]Ast.Node.Index = undefined;
                        const args = builtinArgs(tree, node, &buffer);
                        if (args.len != 2) continue;
                        if (tree.nodeTag(args[1]) != .string_literal) {
                            try found.computed.append(self.gpa, .{ .file = source.id, .node = args[0] });
                            continue;
                        }
                        break :blk .{ args[0], tree.tokenSlice(tree.nodeMainToken(args[1])) };
                    },
                    else => continue,
                };
                const entry = try found.by_name.getOrPut(self.gpa, std.mem.trim(u8, spelled, "\""));
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(self.gpa, .{ .file = source.id, .node = receiver });
            }
        }
    }
    if (found.verdicts.get(name)) |known| return known;
    const wide = self.wide;
    var any = false;
    const named = if (found.by_name.get(name)) |list| list.items else &.{};
    for ([_][]const Key{ named, found.computed.items }) |receivers| for (receivers) |receiver| {
        // A call in code no compilation of the program analyzes calls nothing (std's LLVM
        // builder's `extra.data.name.slice(…)` for a program that never reaches it).
        if (!try self.analyzedAt(receiver.file, receiver.node)) continue;
        if (try self.closedField(receiver)) continue;
        if (try self.mayBeProgram(try self.resolve(receiver.file, receiver.node))) any = true;
        if (any) break;
    };
    if (!self.wideSince(wide)) try found.verdicts.put(self.gpa, name, any);
    return any;
}
const OutsideCalls = struct {
    built: bool = false,
    /// Each name called through a member outside the program, with the receivers it is called on.
    by_name: std.StringHashMapUnmanaged(std.ArrayList(Key)) = .empty,
    /// The receivers of calls through `@field` with a computed name: any name.
    computed: std.ArrayList(Key) = .empty,
    verdicts: std.StringHashMapUnmanaged(bool) = .empty,
};

/// Whether a value may be the program's: it does not resolve, or reaches a container of a
/// program file.
/// Whether `receiver` is a field of code outside the program whose declared type names none of
/// its generic's parameters (`lock: std.atomic.Value(bool)` in aegis's `Guarded(T)`): what it
/// holds is decided there, so never the program's, even where the type itself does not
/// resolve. A type naming a parameter, a builtin or a name that does not resolve may be.
fn closedField(self: *Facts, receiver: Key) ResolveError!bool {
    const tree = &self.project.at(receiver.file).file.tree;
    if (tree.nodeTag(receiver.node) == .identifier) return self.closedLocal(receiver);
    if (tree.nodeTag(receiver.node) != .field_access) return false;
    // A member of a value whose type is closed is that type's, and so closed itself.
    // Where the member's declaration is not known, it is closed only as a member of a holder
    // whose type is.
    const decl = switch (try self.definition(receiver.file, receiver.node)) {
        .decl => |d| d,
        .none, .unknown => return self.closedField(.{ .file = receiver.file, .node = tree.nodeData(receiver.node).node_and_token[0] }),
    };
    if (try self.program(decl.file)) return false;
    const source = self.project.at(decl.file);
    const record = source.model.declarations[@backingInt(decl.index)];
    if (record.kind != .field) return false;
    const field = source.model.containerField(&source.file.tree, record.node) orelse return false;
    return closedType(source, field.ast.type_expr.unwrap() orelse return false, 0);
}

/// Whether `receiver` names a variable or parameter of code outside the program declared with a
/// closed type (`torn: *std.atomic.Value(usize)`), or a constant whose value is closed. A
/// parameter of type `type` or `anytype` may be given the program's.
fn closedLocal(self: *Facts, receiver: Key) ResolveError!bool {
    if (try self.program(receiver.file)) return false;
    const source = self.project.at(receiver.file);
    const tree = &source.file.tree;
    const ref = source.model.reference(receiver.node) orelse return false;
    const declared = source.model.declarations[@backingInt(ref.declaration orelse return false)];
    const type_node = switch (declared.kind) {
        .parameter => declared.node,
        .variable => blk: {
            const variable = tree.fullVarDecl(declared.node) orelse return false;
            if (variable.ast.type_node.unwrap()) |typed| break :blk typed;
            // Untyped, it holds what its initializer reads (`&self.slots[i]`): that value's
            // place, or an expression closed itself.
            var value = variable.ast.init_node.unwrap() orelse return false;
            while (true) switch (tree.nodeTag(value)) {
                .address_of, .deref => value = tree.nodeData(value).node,
                .array_access => value = tree.nodeData(value).node_and_node[0],
                .unwrap_optional, .grouped_expression => value = tree.nodeData(value).node_and_token[0],
                else => break,
            };
            return switch (tree.nodeTag(value)) {
                .identifier, .field_access => self.closedField(.{ .file = receiver.file, .node = value }),
                else => closedType(source, value, 0),
            };
        },
        .function, .capture, .field => return false,
    };
    if (tree.nodeTag(type_node) != .identifier and tree.nodeTag(type_node) != .field_access and tree.nodeTag(type_node) != .call and tree.nodeTag(type_node) != .call_one and tree.nodeTag(type_node) != .ptr_type_aligned and tree.nodeTag(type_node) != .ptr_type and tree.nodeTag(type_node) != .optional_type) return false;
    if (tree.nodeTag(type_node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(type_node)), "type")) return false;
    return closedType(source, type_node, 0);
}

/// Whether the expression `node` of `source` names no parameter or capture, through the
/// constants it names (`const C = Context;`), no builtin and nothing that does not resolve.
fn closedType(source: *const Project.Source, node: Ast.Node.Index, depth: u8) bool {
    if (depth > 4) return false;
    const tree = &source.file.tree;
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    for (tree.nodes.items(.tag), tree.nodes.items(.main_token), 0..) |tag, token, i| {
        if (token < first or token > last) continue;
        switch (tag) {
            .identifier => {
                // A primitive type (`u32`, `bool`) names nothing of the program's; `type` holds
                // whatever type it is given, the program's among them.
                if (std.mem.eql(u8, tree.tokenSlice(token), "type")) return false;
                if (std.zig.primitives.isPrimitive(tree.tokenSlice(token))) continue;
                // An enum's or a union's bare tag (`enum { empty, ready }`) names itself.
                if (source.model.tagName(tree, @fromBackingInt(@intCast(i)))) continue;
                const ref = source.model.reference(@fromBackingInt(@intCast(i))) orelse return false;
                const named = ref.declaration orelse {
                    if (ref.unknown == .primitive) continue;
                    return false;
                };
                const declared = source.model.declarations[@backingInt(named)];
                switch (declared.kind) {
                    .parameter, .capture => return false,
                    .function, .field => {},
                    .variable => {
                        const variable = tree.fullVarDecl(declared.node) orelse return false;
                        if (!closedType(source, variable.ast.init_node.unwrap() orelse return false, depth + 1)) return false;
                    },
                }
            },
            // Its own container, and a file it imports by path: std's `@import("root")` is the
            // program's.
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                const which = tree.tokenSlice(token);
                if (std.mem.eql(u8, which, "@This")) continue;
                if (!std.mem.eql(u8, which, "@import")) return false;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = builtinArgs(tree, @fromBackingInt(@intCast(i)), &buffer);
                if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) return false;
                if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(args[0])), "\"root\"")) return false;
            },
            else => {},
        }
    }
    return true;
}

fn mayBeProgram(self: *Facts, value: Value) ResolveError!bool {
    return switch (value) {
        .unknown => true,
        .container, .instance => |c| try self.program(c.file),
        .pointer => |inner| self.mayBeProgram(inner.child.*),
        .array, .optional, .error_union => |inner| self.mayBeProgram(inner.*),
        .alternatives => |each| for (each) |one| {
            if (try self.mayBeProgram(one)) break true;
        } else false,
        else => false,
    };
}

/// The arguments `parent` passes when it calls what `node` names: `f(a, b)`, or
/// `@call(modifier, f, .{ a, b })`. Null when `parent` does not call it.
fn callParams(tree: *const Ast, parent: Ast.Node.Index, node: Ast.Node.Index, call_buffer: *[1]Ast.Node.Index, tuple_buffer: *[2]Ast.Node.Index) ?[]const Ast.Node.Index {
    if (tree.fullCall(call_buffer, parent)) |call| return if (call.ast.fn_expr == node) call.ast.params else null;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, parent, &buffer);
    if (args.len != 3 or args[1] != node or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parent)), "@call")) return null;
    const tuple = tree.fullArrayInit(tuple_buffer, args[2]) orelse return null;
    if (tuple.ast.type_expr != .none) return null;
    return tuple.ast.elements;
}

/// Whether `parent` uses its operand `node` as only a field can be used: as the target of an
/// assignment, an operand of arithmetic, a comparison or a logical operator, or what an
/// integer builtin reads.
fn fieldUse(tree: *const Ast, parent: Ast.Node.Index, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(parent)) {
        .assign, .assign_mul, .assign_div, .assign_mod, .assign_add, .assign_sub, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_xor, .assign_bit_or, .assign_mul_wrap, .assign_add_wrap, .assign_sub_wrap, .assign_mul_sat, .assign_add_sat, .assign_sub_sat => tree.nodeData(parent).node_and_node[0] == node,
        .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .bool_and, .bool_or, .bool_not, .negation, .negation_wrap, .bit_not, .mul, .mul_wrap, .mul_sat, .div, .mod, .shl, .shl_sat, .shr, .bit_and, .bit_or, .bit_xor, .add, .add_wrap, .add_sat, .sub, .sub_wrap, .sub_sat => true,
        // An integer or an enum's read out of it, which no function is: `@backingInt(m.role)`.
        .builtin_call_two, .builtin_call_two_comma => blk: {
            const name = tree.tokenSlice(tree.nodeMainToken(parent));
            for ([_][]const u8{ "@backingInt", "@intFromEnum", "@intCast", "@truncate", "@tagName" }) |integer| {
                if (std.mem.eql(u8, name, integer)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// What a member access's receiver can be, one by one: each alternative, and a pointer to a
/// choice as a pointer to each of its alternatives.
fn holders(self: *Facts, value: Value) ResolveError![]const Value {
    var list: std.ArrayList(Value) = .empty;
    const outer: []const Value = if (value == .alternatives) value.alternatives else &.{value};
    for (outer) |one| {
        if (one == .pointer and one.pointer.child.* == .alternatives) {
            for (one.pointer.child.alternatives) |inner| try list.append(self.gpa, try self.pointerTo(inner, one.pointer.size));
        } else try list.append(self.gpa, one);
    }
    return list.items;
}

/// Whether `node` is a value the program holds at run time, never a type or a namespace (below).
/// Zig's `@field` on such a value reaches only fields, never a declaration.
pub fn runtime(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    return self.runtimeValue(file, node, 0);
}

/// Whether `node` is a value the program holds at run time, never a type or a namespace: an
/// address taken, a `var`, a parameter declared with a type other than `type`, a `const`
/// declared with such a type or initialized by such a value, or a field of one. A field of a
/// value is a value unless a `comptime` field holds it, so a name some container in the
/// project declares as a `comptime` field is left unknown.
fn runtimeValue(self: *Facts, file: Project.FileId, node: Ast.Node.Index, depth: usize) ResolveError!bool {
    if (depth == 32) return false;
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    switch (tree.nodeTag(node)) {
        .address_of => return true,
        .grouped_expression => return self.runtimeValue(file, tree.nodeData(node).node_and_token[0], depth + 1),
        .field_access => {
            const data = tree.nodeData(node).node_and_token;
            if (try self.comptimeField(try self.memberName(tree.tokenSlice(data[1])))) return false;
            return self.runtimeValue(file, data[0], depth + 1);
        },
        .identifier => {
            const ref = model.reference(node) orelse return false;
            const record = model.declarations[@backingInt(ref.declaration orelse return false)];
            switch (record.kind) {
                .parameter => {
                    const function = self.functionOf(.{ .file = file, .index = ref.declaration.? }) orelse return false;
                    var fn_buffer: [1]Ast.Node.Index = undefined;
                    const proto = tree.fullFnProto(&fn_buffer, model.declarations[@backingInt(function.index)].node) orelse return false;
                    var it = proto.iterate(tree);
                    while (it.next()) |param| {
                        if (param.name_token != record.token) continue;
                        // `anytype` binds a value or a type; dereferenced, it is a pointer.
                        const type_expr = param.type_expr orelse return self.dereferenced(.{ .file = file, .index = ref.declaration.? });
                        return !typeKeyword(tree, type_expr);
                    }
                    return false;
                },
                .variable => {
                    const variable = tree.fullVarDecl(record.node) orelse return false;
                    if (variable.comptime_token != null) return false;
                    if (variable.ast.type_node.unwrap()) |t| return !typeKeyword(tree, t);
                    if (tree.tokenTag(variable.ast.mut_token) == .keyword_var) return true;
                    const init = variable.ast.init_node.unwrap() orelse return false;
                    return self.runtimeValue(file, init, depth + 1);
                },
                else => return false,
            }
        },
        else => return false,
    }
}

/// Whether the program dereferences the declaration `decl` somewhere in its file (`p.*`),
/// which only a pointer allows.
fn dereferenced(self: *Facts, decl: Decl) ResolveError!bool {
    const done = try self.dereferences_found.getOrPut(self.gpa, decl.file);
    if (!done.found_existing) {
        const tree = &self.project.at(decl.file).file.tree;
        const model = &self.project.at(decl.file).model;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .deref) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const operand = tree.nodeData(node).node;
            if (tree.nodeTag(operand) != .identifier) continue;
            const ref = model.reference(operand) orelse continue;
            const index = ref.declaration orelse continue;
            try self.dereferences.put(self.gpa, .{ .file = decl.file, .index = index }, {});
        }
    }
    return self.dereferences.contains(decl);
}

fn typeKeyword(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "type");
}

/// Whether any container in the project declares a `comptime` field named `name`.
fn comptimeField(self: *Facts, name: []const u8) ResolveError!bool {
    if (self.comptime_fields == null) {
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (self.project.sources) |*source| {
            const file = source.file;
            const model = &source.model;
            if (file.status != .parsed) continue;
            for (model.declarations) |d| {
                if (d.kind != .field) continue;
                const field = model.containerField(&file.tree, d.node) orelse continue;
                if (field.comptime_token != null) try names.put(self.gpa, d.name, {});
            }
        }
        self.comptime_fields = names;
    }
    return self.comptime_fields.?.contains(name);
}

/// Whether the call `parent` makes through the member access `node` cannot be `function`:
/// it passes a number of arguments the function takes neither as a method nor by name.
fn cannotBe(self: *Facts, tree: *const Ast, parent: Ast.Node.Index, node: Ast.Node.Index, function: Decl) ResolveError!bool {
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, parent) orelse return false;
    if (call.ast.fn_expr != node) return false;
    const target_tree = &self.project.at(function.file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = target_tree.fullFnProto(&fn_buffer, self.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return false;
    var count: usize = 0;
    var it = proto.iterate(target_tree);
    while (it.next()) |_| count += 1;
    return call.ast.params.len != count and call.ast.params.len + 1 != count;
}

/// Whether `node` is a path of declarations from a module imported by name: `reactor.Loop`.
pub fn throughModule(self: *const Facts, file: Project.FileId, node: Ast.Node.Index) bool {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var at = node;
    while (tree.nodeTag(at) == .field_access) at = tree.nodeData(at).node_and_token[0];
    if (tree.nodeTag(at) != .identifier) return false;
    const ref = model.reference(at) orelse return false;
    const index = ref.declaration orelse return false;
    const record = model.declarations[@backingInt(index)];
    if (record.kind != .variable) return false;
    const variable = tree.fullVarDecl(record.node) orelse return false;
    const init = variable.ast.init_node.unwrap() orelse return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, init, &buffer);
    if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init)), "@import")) return false;
    // A ZON file's value is a value, no module's declarations.
    if (importKind(tree, init) != .namespace) return false;
    return !std.mem.endsWith(u8, tree.tokenSlice(tree.nodeMainToken(args[0])), ".zig\"");
}

fn isTypeQuery(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@TypeOf"),
        else => false,
    };
}

pub fn builtinArgs(tree: *const Ast, node: Ast.Node.Index, buffer: *[2]Ast.Node.Index) []const Ast.Node.Index {
    return tree.builtinCallParams(buffer, node) orelse &.{};
}

/// `node` through the parentheses around it, which give the value they hold.
pub fn ungrouped(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = node;
    while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
    return at;
}

/// The builtin `node` calls (`@field`), by the name Zig gives it, which no declaration can take;
/// null where it calls none.
pub fn builtinName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => tree.tokenSlice(tree.nodeMainToken(node)),
        else => null,
    };
}

/// Whether `node` calls the builtin `name` (`builtinName`).
pub fn isBuiltin(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    return std.mem.eql(u8, builtinName(tree, node) orelse return false, name);
}

/// What an `@import` gives, as Zig decides it by the name imported: a ZON file's
/// (`@import("build.zig.zon")`) is the value the file holds, data that may be any; any other (a
/// module, std, a `.zig` path) is a file's namespace, a type, which holds no runtime value. Null
/// where `node`, its parentheses aside, is no `@import`. A name not written as one string
/// literal, or one this cannot read (longer than a path, an invalid escape), may be either: data.
pub fn importKind(tree: *const Ast, node: Ast.Node.Index) ?enum { namespace, data } {
    const call = ungrouped(tree, node);
    if (!isBuiltin(tree, call, "@import")) return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, call, &buffer);
    if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) return .data;
    var name: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out: std.Io.Writer = .fixed(&name);
    const parsed = std.zig.string_literal.parseWrite(&out, tree.tokenSlice(tree.nodeMainToken(args[0]))) catch return .data;
    if (parsed != .success) return .data;
    return if (std.mem.endsWith(u8, out.buffered(), ".zon")) .data else .namespace;
}

/// The functions each found a view of (`viewOf`).
const Views = struct { found: std.AutoHashMapUnmanaged(Decl, ?usize) = .empty };

/// The position of the parameter whose memory every pointer `function` returns points into: a
/// view of it, as `std.mem.asBytes(ptr)` and `sliceAsBytes(slice)` are. Each `return` gives the
/// parameter through what keeps the memory it points at (`accesses.viewed`: `@ptrCast`,
/// `@alignCast`, `@constCast`, `@volatileCast`, `@as`, a slice of it, parentheses, a variable
/// holding it, each value an `if` or a labeled block chooses), the address of a part of what it
/// points at (`&p.bytes`), or the address of an empty literal (`&[0]u8{}`), no memory at all. Null where one gives anything else, a bare
/// `return`, a body the program does not hold: then what it returns is no known view.
pub fn viewOf(self: *Facts, function: Decl) ResolveError!?usize {
    const views = try self.memo(Views);
    if (views.found.get(function)) |kept| return kept;
    try views.found.put(self.gpa, function, null);
    const found = try self.findView(function);
    try views.found.put(self.gpa, function, found);
    return found;
}

fn findView(self: *Facts, function: Decl) ResolveError!?usize {
    const tree = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const whole = self.scopeNode(function);
    if (tree.nodeTag(whole) != .fn_decl) return null;
    // A result that holds no pointer is a copy, no view of any memory: its body is not read.
    if (!mayPoint(try self.instance(try self.resultOf(.{ .file = function.file, .node = tree.nodeData(whole).node_and_node[0] })))) return null;
    const body = tree.nodeData(whole).node_and_node[1];
    var position: ?usize = null;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < tree.firstToken(body) or token > tree.lastToken(body)) continue;
        // A return of a function declared inside is that function's own.
        var parent = model.parentOf(node);
        while (parent) |p| : (parent = model.parentOf(p)) if (tree.nodeTag(p) == .fn_decl) break;
        if (parent != whole) continue;
        // What it returns, through what keeps an address: a cast, a slice, a constant holding
        // it, a call of a view (`return std.mem.asBytes(p);` is a view of `p` as asBytes is).
        var at = tree.nodeData(node).opt_node.unwrap() orelse return null;
        // The address of an empty literal, through casts, is no memory at all (`bytesAsSlice`'s
        // `&[0]T{}`); its parameters give it no part, so it is read before handsParameter.
        const bare = try self.throughCasts(function.file, at);
        if (tree.nodeTag(bare) == .address_of and emptyLiteral(tree, tree.nodeData(bare).node)) continue;
        // A value its parameters give no part of is no view of one: read by its spelling first,
        // so a call's callee is resolved only where the call is handed one of them.
        if (!try self.handsParameter(function, whole, at, 0, null)) return null;
        for (0..16) |_| {
            at = try accesses.viewed(self, function.file, at);
            switch (tree.nodeTag(at)) {
                .slice_open, .slice, .slice_sentinel => at = tree.fullSlice(at).?.ast.sliced, // unreachable: the tag is a slice's
                else => break,
            }
        }
        // The address of a part of what a pointer parameter points at (`&p.bytes`, `&p.*`): a
        // part of the parameter's memory.
        if (tree.nodeTag(at) == .address_of) at = try accesses.pointeeRoot(self, function.file, tree.nodeData(at).node) orelse return null;
        if (tree.nodeTag(at) != .identifier) return null;
        const named = (model.reference(at) orelse return null).declaration orelse return null;
        const record = model.declarations[@backingInt(named)];
        if (record.kind != .parameter or model.scopes[@backingInt(record.scope)].node != whole) return null;
        const here = self.parameterPosition(function.file, function, record.token) orelse return null;
        if (position) |other| if (other != here) return null;
        position = here;
    }
    return position;
}

/// Whether a value of type `value` may be a pointer: a pointer, an optional or an error union
/// of one, a choice with one, a type that does not resolve or that reflection builds.
fn mayPoint(value: Value) bool {
    return switch (value) {
        .pointer, .unknown, .reflected, .reified, .literal => true,
        .optional, .error_union => |inner| mayPoint(inner.*),
        .alternatives => |each| for (each) |one| {
            if (mayPoint(one)) break true;
        } else false,
        .primitive, .container, .instance, .function, .array, .error_set, .scalar, .fn_type => false,
    };
}

const Readers = struct { found: std.AutoHashMapUnmanaged(Decl, ?Reader) = .empty };

/// The parameter whose memory every value a function returns is read out of, and whether the
/// function reads it as another type itself (`recast`).
pub const Reader = struct { from: usize, recast: bool };

/// How `function` reads memory out: each `return` gives a value read through a pointer its
/// parameter at one position gives, an element of it or what it points at, through what keeps
/// the value (`@byteSwap`, `@as`, each prong of a `switch` or an `if`, a constant holding it)
/// and what reads it as another type (`@bitCast`; a pointer that reinterprets the memory):
/// `std.mem.bytesToValue`'s `bytesAsValue(T, bytes).*`, `toBytes`'s `asBytes(&value).*`,
/// `readInt`'s `@bitCast(buffer.*)`, a getter's `p.*`. Null where one gives anything else.
pub fn readOf(self: *Facts, function: Decl) ResolveError!?Reader {
    const readers = try self.memo(Readers);
    if (readers.found.get(function)) |kept| return kept;
    try readers.found.put(self.gpa, function, null);
    const found = try self.findReader(function);
    try readers.found.put(self.gpa, function, found);
    return found;
}

fn findReader(self: *Facts, function: Decl) ResolveError!?Reader {
    const tree = self.syntaxOf(function.file);
    const whole = self.scopeNode(function);
    if (tree.nodeTag(whole) != .fn_decl) return null;
    const body = tree.nodeData(whole).node_and_node[1];
    var found: ?Reader = null;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (!self.ownStatement(function.file, whole, body, node)) continue;
        const here = try self.readFrom(function, whole, tree.nodeData(node).opt_node.unwrap() orelse return null, 0) orelse return null;
        if (found) |other| {
            if (other.from != here.from) return null;
            found = .{ .from = here.from, .recast = other.recast or here.recast };
        } else found = here;
    }
    return found;
}

/// The memory the value `node` is read out of (`readOf`): through `@byteSwap`, `@as`, a
/// constant, each prong of a `switch` or an `if`; `@bitCast` and a reinterpreting pointer read
/// it as another type.
fn readFrom(self: *Facts, function: Decl, whole: Ast.Node.Index, node: Ast.Node.Index, depth: u8) ResolveError!?Reader {
    if (depth >= 16) return null;
    const tree = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const at = try self.throughCasts(function.file, node);
    switch (tree.nodeTag(at)) {
        .deref, .array_access => {
            const pointer = if (tree.nodeTag(at) == .deref) tree.nodeData(at).node else tree.nodeData(at).node_and_node[0];
            // `.*` reads through a pointer whatever its type resolves to; an element, only where
            // what it indexes is one, not an array held by value.
            if (tree.nodeTag(at) == .array_access and !accesses.pointing(try self.resolve(function.file, pointer))) return null;
            var memory = try accesses.viewed(self, function.file, pointer);
            if (tree.nodeTag(memory) == .address_of) memory = tree.nodeData(memory).node;
            const from = try self.reachedParameter(function, whole, memory) orelse return null;
            return .{ .from = from, .recast = try accesses.reinterprets(self, function.file, pointer) };
        },
        .identifier => {
            const d = (model.reference(at) orelse return null).declaration orelse return null;
            const record = model.declarations[@backingInt(d)];
            if (record.kind != .variable) return null;
            const variable = tree.fullVarDecl(record.node) orelse return null;
            if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
            return self.readFrom(function, whole, variable.ast.init_node.unwrap() orelse return null, depth + 1);
        },
        else => {},
    }
    if (valueKept(tree, at)) |kept| {
        const inner = try self.readFrom(function, whole, kept.operand, depth + 1) orelse return null;
        return .{ .from = inner.from, .recast = inner.recast or kept.recast };
    }
    var found: ?Reader = null;
    for (try self.prongs(tree, at) orelse return null) |value| {
        const here = try self.readFrom(function, whole, value, depth + 1) orelse return null;
        if (found) |other| {
            if (other.from != here.from) return null;
            found = .{ .from = here.from, .recast = other.recast or here.recast };
        } else found = here;
    }
    return found;
}

/// The operand a builtin gives the value of, as the same bits (`@byteSwap`, `@bitReverse`) or
/// as another type (`@bitCast`: `recast`).
fn valueKept(tree: *const Ast, node: Ast.Node.Index) ?struct { operand: Ast.Node.Index, recast: bool } {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, node, &buffer);
    if (args.len != 1) return null;
    if (std.mem.eql(u8, name, "@bitCast")) return .{ .operand = args[0], .recast = true };
    if (std.mem.eql(u8, name, "@byteSwap") or std.mem.eql(u8, name, "@bitReverse")) return .{ .operand = args[0], .recast = false };
    return null;
}

/// The values a `switch` or an `if` gives, one per prong; null for anything else, and for an
/// `if` with no `else`.
fn prongs(self: *Facts, tree: *const Ast, node: Ast.Node.Index) ResolveError!?[]const Ast.Node.Index {
    if (tree.fullIf(node)) |full| return try self.gpa.dupe(Ast.Node.Index, &.{ full.ast.then_expr, full.ast.else_expr.unwrap() orelse return null });
    const full = tree.fullSwitch(node) orelse return null;
    const out = try self.gpa.alloc(Ast.Node.Index, full.ast.cases.len);
    for (full.ast.cases, out) |case, *value| value.* = tree.fullSwitchCase(case).?.ast.target_expr; // unreachable: a switch's cases are cases
    return out;
}

const Copiers = struct { found: std.AutoHashMapUnmanaged(Decl, ?Copier) = .empty };

/// The parameters a function copies memory between: what `from` points at or holds into what
/// `into` points at; where `exchange`, each into the other (a swap, which duplicates nothing).
pub const Copier = struct { into: usize, from: usize, exchange: bool = false };

/// How `function` copies memory, where every store its body makes writes, through what one
/// parameter points at, a value read from what another points at or holds, through what keeps
/// the value (`@bitCast`, `@byteSwap`, each prong of a `switch` or an `if`, a constant), and it
/// makes one: `std.mem.copyForwards` (`for (dest[0..source.len], source) |*d, s| d.* = s;`),
/// copyBackwards (`dest[i] = source[i]`), a function around `@memcpy`, `writeInt`'s
/// `buffer.* = @bitCast(value)`, a setter's `raw.* = v`; a call of a copier copies as it does,
/// between what its arguments give (a function around `copyForwards`). Two stores each way
/// between the same two are an exchange (`std.mem.swap`). Null where a store writes other
/// memory or what no one parameter gives, or two pair other parameters.
pub fn copierOf(self: *Facts, function: Decl) ResolveError!?Copier {
    const copiers = try self.memo(Copiers);
    if (copiers.found.get(function)) |kept| return kept;
    try copiers.found.put(self.gpa, function, null);
    const found = try self.findCopier(function);
    try copiers.found.put(self.gpa, function, found);
    return found;
}

fn findCopier(self: *Facts, function: Decl) ResolveError!?Copier {
    const tree = self.syntaxOf(function.file);
    const whole = self.scopeNode(function);
    if (tree.nodeTag(whole) != .fn_decl) return null;
    const body = tree.nodeData(whole).node_and_node[1];
    var found: ?Copier = null;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const into_node: Ast.Node.Index, const from_node: Ast.Node.Index, const exchange: bool = switch (tag) {
            // A store to a local of its own (`i -= 1`) is its bookkeeping, no memory it is given.
            .assign, .assign_mul, .assign_div, .assign_mod, .assign_add, .assign_sub, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_xor, .assign_bit_or, .assign_mul_wrap, .assign_add_wrap, .assign_sub_wrap, .assign_mul_sat, .assign_add_sat, .assign_sub_sat => blk: {
                if (!self.ownStatement(function.file, whole, body, node)) continue;
                const target, const value = tree.nodeData(node).node_and_node;
                if (self.ownLocal(function.file, whole, target)) continue;
                if (tag != .assign) return null;
                break :blk .{ target, value, false };
            },
            .assign_destructure, .asm_simple, .@"asm" => if (self.ownStatement(function.file, whole, body, node)) return null else continue,
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => blk: {
                if (!self.ownStatement(function.file, whole, body, node)) continue;
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                var buffer: [2]Ast.Node.Index = undefined;
                const args = builtinArgs(tree, node, &buffer);
                if ((std.mem.eql(u8, name, "@memcpy") or std.mem.eql(u8, name, "@memmove")) and args.len == 2) break :blk .{ args[0], args[1], false };
                for (accesses.writer_builtins) |entry| if (std.mem.eql(u8, name, entry[0])) return null;
                continue;
            },
            // A copier's call copies between what its arguments give.
            .call_one, .call_one_comma, .call, .call_comma => blk: {
                if (!self.ownStatement(function.file, whole, body, node)) continue;
                const call = (try calls.at(self, function.file, node)) orelse continue;
                const args = switch (call.args) {
                    .known => |each| each,
                    .unknown => continue,
                };
                const inner = switch (call.callee) {
                    .function => |callee| try self.copierOf(callee) orelse continue,
                    else => continue,
                };
                if (inner.into >= args.len or inner.from >= args.len) continue;
                break :blk .{ args[inner.into], args[inner.from], inner.exchange };
            },
            else => continue,
        };
        const into = try self.reachedParameter(function, whole, into_node) orelse return null;
        const from = try self.givenParameter(function, whole, from_node, 0) orelse return null;
        if (into == from) return null;
        const one: Copier = .{ .into = into, .from = from, .exchange = exchange };
        found = if (found) |other| (copierJoin(other, one) orelse return null) else one;
    }
    return found;
}

/// Two copies one body makes as one: the same, or each way between the same two (an exchange).
fn copierJoin(a: Copier, b: Copier) ?Copier {
    if (a.into == b.into and a.from == b.from) return .{ .into = a.into, .from = a.from, .exchange = a.exchange or b.exchange };
    if (a.into == b.from and a.from == b.into) return .{ .into = a.into, .from = a.from, .exchange = true };
    return null;
}

/// The parameter whose memory or value the value `node` gives (`reachedParameter`), through
/// what keeps the value: `@bitCast`, `@byteSwap`, a constant, each prong of a `switch` or an
/// `if`, all the same one.
fn givenParameter(self: *Facts, function: Decl, whole: Ast.Node.Index, node: Ast.Node.Index, depth: u8) ResolveError!?usize {
    if (depth >= 16) return null;
    const tree = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const at = try self.throughCasts(function.file, node);
    if (valueKept(tree, at)) |kept| return self.givenParameter(function, whole, kept.operand, depth + 1);
    if (try self.prongs(tree, at)) |each| {
        var found: ?usize = null;
        for (each) |value| {
            const here = try self.givenParameter(function, whole, value, depth + 1) orelse return null;
            if (found) |other| if (other != here) return null;
            found = here;
        }
        return found;
    }
    if (tree.nodeTag(at) == .identifier) if (model.reference(at)) |reference| if (reference.declaration) |d| {
        const record = model.declarations[@backingInt(d)];
        if (record.kind == .variable) if (tree.fullVarDecl(record.node)) |variable| {
            if (tree.tokenTag(variable.ast.mut_token) == .keyword_const) return self.givenParameter(function, whole, variable.ast.init_node.unwrap() orelse return null, depth + 1);
        };
    };
    return self.reachedParameter(function, whole, at);
}

/// Whether `target` names a variable the function `whole` declares, by its name.
fn ownLocal(self: *Facts, file: Project.FileId, whole: Ast.Node.Index, target: Ast.Node.Index) bool {
    const tree = self.syntaxOf(file);
    const model = &self.project.at(file).model;
    if (tree.nodeTag(target) != .identifier) return false;
    const d = (model.reference(target) orelse return false).declaration orelse return false;
    const record = model.declarations[@backingInt(d)];
    if (record.kind != .variable) return false;
    var parent = model.parentOf(record.node);
    while (parent) |p| : (parent = model.parentOf(p)) if (tree.nodeTag(p) == .fn_decl) break;
    return parent == whole;
}

/// Whether `node` is in `body` of the function `whole`, not of one declared inside it.
fn ownStatement(self: *Facts, file: Project.FileId, whole: Ast.Node.Index, body: Ast.Node.Index, node: Ast.Node.Index) bool {
    const tree = self.syntaxOf(file);
    const model = &self.project.at(file).model;
    const token = tree.nodeMainToken(node);
    if (token < tree.firstToken(body) or token > tree.lastToken(body)) return false;
    var parent = model.parentOf(node);
    while (parent) |p| : (parent = model.parentOf(p)) if (tree.nodeTag(p) == .fn_decl) break;
    return parent == whole;
}

/// The parameter of `function` whose memory `node` names, through a dereference, an element,
/// a member, a payload, a slice, an address, a cast, a view's call, a `for` capture of an input
/// (`|*d|` over `dest[0..n]`) and a constant's initializer.
fn reachedParameter(self: *Facts, function: Decl, whole: Ast.Node.Index, node: Ast.Node.Index) ResolveError!?usize {
    const tree = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    var at = node;
    for (0..16) |_| {
        at = try self.throughCasts(function.file, at);
        switch (tree.nodeTag(at)) {
            .deref => at = tree.nodeData(at).node,
            .array_access => at = tree.nodeData(at).node_and_node[0],
            .field_access, .unwrap_optional => at = tree.nodeData(at).node_and_token[0],
            .slice_open, .slice, .slice_sentinel => at = tree.fullSlice(at).?.ast.sliced, // unreachable: the tag is a slice's
            .address_of => at = tree.nodeData(at).node,
            .call_one, .call_one_comma, .call, .call_comma => {
                // A view's call: the memory of what it views (`std.mem.asBytes(p)`).
                const through = try accesses.viewed(self, function.file, at);
                if (through == at) return null;
                at = through;
            },
            .identifier => {
                const d = (model.reference(at) orelse return null).declaration orelse return null;
                const record = model.declarations[@backingInt(d)];
                switch (record.kind) {
                    .parameter => {
                        if (model.scopes[@backingInt(record.scope)].node != whole) return null;
                        return self.parameterPosition(function.file, function, record.token);
                    },
                    .capture => {
                        const loop = tree.fullFor(record.node) orelse return null;
                        const position = Model.capturePosition(tree, loop, record.token) orelse return null;
                        if (position >= loop.ast.inputs.len or tree.nodeTag(loop.ast.inputs[position]) == .for_range) return null;
                        at = loop.ast.inputs[position];
                    },
                    .variable => {
                        const variable = tree.fullVarDecl(record.node) orelse return null;
                        if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
                        at = variable.ast.init_node.unwrap() orelse return null;
                    },
                    else => return null,
                }
            },
            else => return null,
        }
    }
    return null;
}

/// Whether the expression `node` in `function` may hand on one of its parameters, by its
/// spelling alone: the parameter itself, through parentheses, a cast, a slice, an address, a
/// member or an element; a constant whose initializer may; a variable of the function's own one
/// of whose values may (`givenTo`; any, where one may go unseen); a call one of whose
/// arguments, or whose receiver, may; an `if`, a `switch`, a labeled block, `orelse` or `catch`
/// one of whose values may (`accesses.valuesOf`; one not read there may). What spells none (a
/// literal, a global, a call given none) is no view of a parameter. A variable whose value is
/// read again from its own (`p = p[1..]`, `held`) hands on only what its other values do.
const Held = struct { decl: Model.Declaration.Id, up: ?*const Held };

fn handsParameter(self: *Facts, function: Decl, whole: Ast.Node.Index, node: Ast.Node.Index, depth: u8, held: ?*const Held) ResolveError!bool {
    if (depth >= 16) return true;
    const tree = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    switch (tree.nodeTag(node)) {
        .grouped_expression, .unwrap_optional, .field_access => return self.handsParameter(function, whole, tree.nodeData(node).node_and_token[0], depth + 1, held),
        .address_of, .deref, .@"try" => return self.handsParameter(function, whole, tree.nodeData(node).node, depth + 1, held),
        .array_access => return self.handsParameter(function, whole, tree.nodeData(node).node_and_node[0], depth + 1, held),
        .slice_open, .slice, .slice_sentinel => return self.handsParameter(function, whole, tree.fullSlice(node).?.ast.sliced, depth + 1, held), // unreachable: the tag is a slice's
        .identifier => {
            const named = (model.reference(node) orelse return false).declaration orelse return false;
            const record = model.declarations[@backingInt(named)];
            switch (record.kind) {
                .parameter => return model.scopes[@backingInt(record.scope)].node == whole,
                .variable => {
                    const variable = tree.fullVarDecl(record.node) orelse return false;
                    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) {
                        if (!self.enclosed(function.file, record.scope, whole)) return false;
                        var up = held;
                        while (up) |each| : (up = each.up) if (each.decl == named) return false;
                        const here: Held = .{ .decl = named, .up = held };
                        for ((try self.givenTo(.{ .file = function.file, .index = named }, false)) orelse return true) |given| {
                            if (try self.handsParameter(function, whole, given.node, depth + 1, &here)) return true;
                        }
                        return false;
                    }
                    const init = variable.ast.init_node.unwrap() orelse return false;
                    return self.handsParameter(function, whole, init, depth + 1, held);
                },
                else => return false,
            }
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            var buffer: [2]Ast.Node.Index = undefined;
            for (builtinArgs(tree, node, &buffer)) |arg| if (try self.handsParameter(function, whole, arg, depth + 1, held)) return true;
            return false;
        },
        else => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, node) orelse {
                const leaves = switch (try accesses.valuesOf(self, function.file, node)) {
                    .leaves => |each| each,
                    .unknown => return true,
                };
                // A value of no form that chooses or carries one: none it hands on.
                if (leaves.len == 1 and leaves[0] == node) return false;
                for (leaves) |leaf| if (try self.handsParameter(function, whole, leaf, depth + 1, held)) return true;
                return false;
            };
            for (call.ast.params) |arg| if (try self.handsParameter(function, whole, arg, depth + 1, held)) return true;
            // A method's receiver: `p.view()` hands `p` on.
            if (tree.nodeTag(call.ast.fn_expr) == .field_access) return self.handsParameter(function, whole, tree.nodeData(call.ast.fn_expr).node_and_token[0], depth + 1, held);
            return false;
        },
    }
}

/// Whether `node` is a literal of no elements or fields: `[0]u8{}`, `.{}`.
fn emptyLiteral(tree: *const Ast, node: Ast.Node.Index) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullArrayInit(&buffer, node)) |literal| return literal.ast.elements.len == 0;
    if (tree.fullStructInit(&buffer, node)) |literal| return literal.ast.fields.len == 0;
    return false;
}

/// Where the program writes, reads and takes the address of each place: the one index every
/// analysis asks "where is this written or read" (`Facts.accesses`). A place is a variable, a
/// parameter or a capture by its declaration, or a container's field in every value of the
/// container. Each file is walked once, the first time a query reaches it, and each site is
/// classified to the place it reaches by meaning: the declaration a name refers to, the field a
/// member or `@field` resolves to through its holder's type, never the spelling alone.
///
/// Writes: `x = v` (W1), `x op= v` (W2), a destructure's target (W3), `@field(h, "f") = v` and
/// one with a computed name (W4), a pointer capture `|*p|` over an array (W5, its address), `&x`
/// (W6, an address), a store through a pointer (`p.* = v`, `p.f = v`, W7), a whole value stored
/// over the fields it holds (`s = t`, W8), the memory builtins (W9), a cast that makes a value of
/// a type from other memory (W10), a pointer handed to a function whose body the program does
/// not hold (W11), an element store (W12), one in a `defer` or `errdefer` (W13, marked) and `asm`
/// (W14). Reads: a name (R1), `x.f` (R2), `@field` (R3), a by-value capture (R4), a copy or a
/// value passed (R5), `&x` (R6, an address), and the memory builtins (R7: a copy's source, an
/// atomic's).
///
/// A site whose place does not resolve is never skipped. A member written on a holder whose type
/// does not resolve is kept by the member's name, and a query for a field so named gets it
/// (`.named`); a store of a whole value whose type does not resolve, or of memory nothing names
/// (`asm`, a pointer of an unknown type handed out, a computed `@field` on an unknown holder),
/// is kept as unresolved, and every query for a place it may reach gets it (`.unresolved`). A
/// file the front end refused gives one unresolved site.
pub const accesses = struct {
    /// Whether `node` is a literal that holds no memory and names no type, whatever type its
    /// use gives it: an enum, number or character literal, or `{}`.
    pub fn inert(tree: *const Ast, node: Ast.Node.Index) bool {
        return switch (tree.nodeTag(node)) {
            .enum_literal, .number_literal, .char_literal => true,
            .block_two => tree.nodeData(node).opt_node_and_opt_node[0] == .none,
            else => false,
        };
    }

    /// The store whose target is `target`, read from `storesIn` alone: `x = v`, `x op= v`, a
    /// destructure's target. Null where no store writes it (`_`, a node no store targets).
    pub fn storeInto(facts: *Facts, file: Project.FileId, target: Ast.Node.Index) Error!?Site {
        for (try storesIn(facts, file)) |site| if (site.target) |each| if (each == target) return site;
        return null;
    }

    /// What memory the store into `target` writes (`storeInto`): a variable's own, by its name
    /// (`box.g = v`, `pair[0] = v`, `x = v`), memory reached through a pointer (`p.g = v`,
    /// `p.* = v`), or memory that does not resolve.
    pub const Stored = union(enum) { declaration: Facts.Decl, through, unresolved };

    pub fn storedIn(facts: *Facts, file: Project.FileId, target: Ast.Node.Index) Error!Stored {
        const store = (try storeInto(facts, file, target)) orelse return .unresolved;
        if (store.through) return .through;
        var it = (try writesOf(facts, file)).places.iterator();
        while (it.next()) |entry| {
            const d = switch (entry.key_ptr.*) {
                .declaration => |d| d,
                .field => continue,
            };
            for (entry.value_ptr.items) |site| if (site.node == store.node and site.kind != .read and site.kind != .address and !site.through) return .{ .declaration = d };
        }
        return .unresolved;
    }

    /// The forms an expression stands in, one for each syntax tag that may hold it: every tag
    /// Zig has is named in `formOf`, with no default, so a tag a new Zig adds fails to build
    /// until it is placed; and each form is checked against the construct matrix's row of every
    /// tag it holds (`Form.rows`, Constructs.ofNode).
    pub const Form = enum {
        /// Statements or members: a file, a test, a block, a container's declarations.
        body,
        deferred,
        variable,
        field_declaration,
        assign,
        compound_assign,
        destructure,
        member,
        unwrap_optional,
        tried,
        @"catch",
        @"orelse",
        comparison,
        operator,
        /// `and`, `or`, `!`: a condition's parts (`conditionOf`).
        logic,
        concatenation,
        address_of,
        slice,
        deref,
        array_access,
        array_literal,
        struct_literal,
        call,
        builtin,
        @"switch",
        prong,
        prong_range,
        @"while",
        @"for",
        for_range,
        @"if",
        @"continue",
        @"break",
        @"return",
        /// Types, each holding a type or what only a type reads (a length, an alignment): `?T`,
        /// an array's, a pointer's, `anyframe->T`, `E!T`, `A || B`, a function's prototype.
        optional_type,
        array_type,
        pointer_type,
        anyframe_type,
        error_union,
        merged_errors,
        prototype,
        grouped,
        @"comptime",
        @"nosuspend",
        /// `suspend` and `resume`: async frames, which glint does not read.
        frame,
        @"asm",
        fn_decl,
        /// A form that holds no expression: a name, a literal.
        leaf,

        /// The construct matrix's rows a tag of this form may be in.
        pub fn rows(form: Form) []const Constructs.Row {
            return switch (form) {
                .body => &.{ .none, .jump },
                .deferred => &.{.deferred},
                .variable, .assign => &.{.assignment},
                .destructure => &.{.destructure},
                .compound_assign, .comparison, .operator, .logic => &.{.operator},
                .unwrap_optional, .tried, .@"catch", .@"orelse" => &.{.unwrap},
                .member, .address_of, .slice, .deref, .array_access => &.{.address},
                .concatenation, .array_literal, .struct_literal => &.{.aggregate},
                .call, .builtin, .frame, .@"asm" => &.{.call},
                .@"switch" => &.{.branch},
                .prong => &.{ .capture, .inline_loop },
                .prong_range, .@"while", .@"for", .for_range, .@"if" => &.{.capture},
                .@"continue", .@"break", .@"return" => &.{.jump},
                .@"comptime" => &.{.compile_time},
                .field_declaration, .optional_type, .array_type, .pointer_type, .anyframe_type, .error_union, .merged_errors, .prototype, .grouped, .@"nosuspend", .fn_decl => &.{.none},
                .leaf => &.{ .none, .address },
            };
        }
    };

    /// The form of a syntax tag, for each tag Zig has.
    pub fn formOf(tag: Ast.Node.Tag) Form {
        return switch (tag) {
            .root, .test_decl, .block_two, .block_two_semicolon, .block, .block_semicolon => .body,
            .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing, .container_decl_arg, .container_decl_arg_trailing => .body,
            .tagged_union, .tagged_union_trailing, .tagged_union_two, .tagged_union_two_trailing, .tagged_union_enum_tag, .tagged_union_enum_tag_trailing => .body,
            .@"defer", .@"errdefer" => .deferred,
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => .variable,
            .container_field_init, .container_field_align, .container_field => .field_declaration,
            .assign => .assign,
            .assign_mul, .assign_div, .assign_mod, .assign_add, .assign_sub, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_xor, .assign_bit_or, .assign_mul_wrap, .assign_add_wrap, .assign_sub_wrap, .assign_mul_sat, .assign_add_sat, .assign_sub_sat => .compound_assign,
            .assign_destructure => .destructure,
            .field_access => .member,
            .unwrap_optional => .unwrap_optional,
            .@"try" => .tried,
            .@"catch" => .@"catch",
            .@"orelse" => .@"orelse",
            .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal => .comparison,
            .mul, .div, .mod, .mul_wrap, .mul_sat, .add, .sub, .add_wrap, .sub_wrap, .add_sat, .sub_sat, .shl, .shl_sat, .shr, .bit_and, .bit_xor, .bit_or, .negation, .bit_not, .negation_wrap => .operator,
            .bool_and, .bool_or, .bool_not => .logic,
            .array_cat => .concatenation,
            .address_of => .address_of,
            .slice_open, .slice, .slice_sentinel => .slice,
            .deref => .deref,
            .array_access => .array_access,
            .array_init_one, .array_init_one_comma, .array_init_dot_two, .array_init_dot_two_comma, .array_init_dot, .array_init_dot_comma, .array_init, .array_init_comma => .array_literal,
            .struct_init_one, .struct_init_one_comma, .struct_init_dot_two, .struct_init_dot_two_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init, .struct_init_comma => .struct_literal,
            .call_one, .call_one_comma, .call, .call_comma => .call,
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => .builtin,
            .@"switch", .switch_comma => .@"switch",
            .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => .prong,
            .switch_range => .prong_range,
            .while_simple, .while_cont, .@"while" => .@"while",
            .for_simple, .@"for" => .@"for",
            .for_range => .for_range,
            .if_simple, .@"if" => .@"if",
            .@"continue" => .@"continue",
            .@"break" => .@"break",
            .@"return" => .@"return",
            .optional_type => .optional_type,
            .array_type, .array_type_sentinel => .array_type,
            .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => .pointer_type,
            .anyframe_type => .anyframe_type,
            .error_union => .error_union,
            .merge_error_sets => .merged_errors,
            .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => .prototype,
            .grouped_expression => .grouped,
            .@"comptime" => .@"comptime",
            .@"nosuspend" => .@"nosuspend",
            .@"suspend", .@"resume" => .frame,
            .asm_simple, .@"asm", .asm_output, .asm_input => .@"asm",
            .fn_decl => .fn_decl,
            .anyframe_literal, .char_literal, .number_literal, .unreachable_literal, .identifier, .enum_literal, .string_literal, .multiline_string_literal, .error_value, .error_set_decl => .leaf,
        };
    }

    /// How a value reaches the expression that carries it on (`Use.carried`).
    pub const Carry = enum {
        /// Parentheses.
        grouped,
        /// `x.?`: the optional's payload.
        unwrapped,
        /// `try x`: the error union's payload.
        tried,
        /// The left of `orelse` or `catch`: its payload.
        payload,
        /// The right of `orelse` or `catch`: given in its stead.
        otherwise,
        /// A branch's or a prong's result, or a loop's `else`: what the `if`, `switch` or loop gives.
        prong,
        /// `break v`: what the block, loop or switch it leaves gives.
        broken,
        /// `comptime x`.
        compile_time,
        /// `nosuspend x`.
        @"nosuspend",
    };

    /// What an expression's value does where it stands, by the form that holds it.
    pub const Use = union(enum) {
        /// A statement, a body, a member, a `defer`'s expression: no value is taken from it.
        statement,
        /// A type, or what only a type reads: which part of which type or declaration.
        typed: Typed,
        /// The first value of the variable or field the declaration at the node declares.
        initializes: Ast.Node.Index,
        /// The target of a store (`x = v`, a destructure's): the store.
        written: Site,
        /// The target of a store that reads it first (`x op= v`): the store.
        updated: Site,
        /// The value a store writes into its target (`x = v`'s `v`): the store.
        stored: Site,
        /// `_ = v`'s `v`, or `_` itself: no place takes it.
        discarded,
        /// The value a destructure takes apart (the destructure).
        destructured: Ast.Node.Index,
        /// The holder of a member read (`x.f`, the access).
        member: Ast.Node.Index,
        /// What is indexed (`x[i]`, the access).
        element: Ast.Node.Index,
        /// What is sliced (`x[a..b]`, the slice).
        sliced: Ast.Node.Index,
        /// What is dereferenced (`x.*`).
        dereferenced: Ast.Node.Index,
        /// An index, a slice's bound or sentinel (the access).
        index: Ast.Node.Index,
        /// What `&` takes the address of.
        address: Ast.Node.Index,
        /// A comparison's operand.
        compared: Ast.Node.Index,
        /// An operator's operand (arithmetic, bits, truth values), a compound assignment's value,
        /// a `for` range's bound.
        operand: Ast.Node.Index,
        /// An operand of `++`.
        concatenated: Ast.Node.Index,
        /// A part of `a and b`, `a or b` or `!a` (`whole`): its right side is read only where its
        /// left side has made the whole undecided (true for `and`, false for `or`).
        logic: struct { whole: Ast.Node.Index, side: enum { left, right, negated } },
        /// An element of an array literal, at its position.
        element_of: struct { literal: Ast.Node.Index, position: usize },
        /// A field of a struct literal, by the token naming it.
        field_of: struct { literal: Ast.Node.Index, name: Ast.TokenIndex },
        /// What a call calls.
        callee: Ast.Node.Index,
        /// A call's argument at a position.
        argument: struct { call: Ast.Node.Index, position: usize },
        /// A builtin's argument at a position.
        builtin_argument: struct { call: Ast.Node.Index, position: usize },
        /// An `if`'s or `while`'s condition (its capture, if any, takes the payload).
        tested: Ast.Node.Index,
        /// A `switch`'s operand.
        switched: Ast.Node.Index,
        /// A prong's item, or a bound of a prong's range (the prong or the range).
        matched: Ast.Node.Index,
        /// A `for`'s input at a position.
        looped: struct { loop: Ast.Node.Index, position: usize },
        /// Carried on to the expression that gives it (`into`).
        carried: struct { into: Ast.Node.Index, how: Carry },
        /// `return v`'s `v`.
        returned: Ast.Node.Index,
        /// `continue :label v`'s `v`.
        continued: Ast.Node.Index,
        /// An `asm` operand or template.
        in_asm: Ast.Node.Index,
        /// What it does is not read here: never clears.
        unknown: Facts.Unknown,
    };

    /// A type's or a declaration's part an expression is (`Use.typed`), and the node it is part of.
    pub const Typed = struct { of: Ast.Node.Index, part: TypePart };
    pub const TypePart = enum {
        /// A variable's, a field's or a parameter's declared type.
        declared,
        /// A function's prototype, of its declaration.
        signature,
        /// The type a struct or an array literal names.
        literal,
        /// A prototype's parameter type, or its result type.
        parameter,
        result,
        /// What `*T`, `?T` and `anyframe->T` hold; an array's element; `E!T`'s set and payload;
        /// an operand of `A || B`.
        pointer_child,
        optional_child,
        frame_result,
        array_element,
        error_set,
        error_payload,
        /// An array's length, a sentinel, an alignment, a pointer's bit range, an address space,
        /// a link section, a calling convention.
        length,
        sentinel,
        alignment,
        bit_range,
        address_space,
        section,
        calling_convention,
    };

    fn typed(of: Ast.Node.Index, part: TypePart) Use {
        return .{ .typed = .{ .of = of, .part = part } };
    }

    /// What `node`'s value does where it stands: read by the form of the node that holds it
    /// (`formOf`), a store's by its site (`storeInto`).
    pub fn useOf(facts: *Facts, file: Project.FileId, node: Ast.Node.Index) Error!Use {
        const tree = &facts.project.at(file).file.tree;
        const model = &facts.project.at(file).model;
        const parent = model.parentOf(node) orelse return .statement;
        switch (formOf(tree.nodeTag(parent))) {
            .body, .deferred => return .statement,
            .optional_type, .anyframe_type, .merged_errors, .error_union, .array_type, .pointer_type, .prototype, .fn_decl, .variable, .field_declaration => return declarationUse(tree, model, parent, node),
            .assign => {
                const target = tree.nodeData(parent).node_and_node[0];
                const site = (try storeInto(facts, file, target)) orelse return if (discard(tree, target)) .discarded else .{ .unknown = .unsupported };
                return if (node == target) .{ .written = site } else .{ .stored = site };
            },
            .compound_assign => {
                const target = tree.nodeData(parent).node_and_node[0];
                if (node != target) return .{ .operand = parent };
                return if (try storeInto(facts, file, target)) |site| .{ .updated = site } else .{ .unknown = .unsupported };
            },
            .destructure => {
                if (tree.assignDestructure(parent).ast.value_expr == node) return .{ .destructured = parent };
                if (try storeInto(facts, file, node)) |site| return .{ .written = site };
                return if (discard(tree, node)) .discarded else .{ .unknown = .unsupported };
            },
            .member => return .{ .member = parent },
            .unwrap_optional => return .{ .carried = .{ .into = parent, .how = .unwrapped } },
            .tried => return .{ .carried = .{ .into = parent, .how = .tried } },
            .@"catch", .@"orelse" => return .{ .carried = .{ .into = parent, .how = if (tree.nodeData(parent).node_and_node[0] == node) .payload else .otherwise } },
            .comparison => return .{ .compared = parent },
            .operator => return .{ .operand = parent },
            .logic => return .{ .logic = .{ .whole = parent, .side = if (tree.nodeTag(parent) == .bool_not) .negated else if (tree.nodeData(parent).node_and_node[0] == node) .left else .right } },
            .concatenation => return .{ .concatenated = parent },
            .address_of => return .{ .address = parent },
            .slice => return if (tree.fullSlice(parent).?.ast.sliced == node) .{ .sliced = parent } else .{ .index = parent }, // unreachable: the form is a slice's
            .deref => return .{ .dereferenced = parent },
            .array_access => return if (tree.nodeData(parent).node_and_node[0] == node) .{ .element = parent } else .{ .index = parent },
            .array_literal => {
                var buffer: [2]Ast.Node.Index = undefined;
                for (tree.fullArrayInit(&buffer, parent).?.ast.elements, 0..) |each, k| if (each == node) return .{ .element_of = .{ .literal = parent, .position = k } }; // unreachable: the form is an array literal's
                return typed(parent, .literal);
            },
            .struct_literal => {
                var buffer: [2]Ast.Node.Index = undefined;
                for (tree.fullStructInit(&buffer, parent).?.ast.fields) |each| if (each == node) { // unreachable: the form is a struct literal's
                    return .{ .field_of = .{ .literal = parent, .name = Model.initName(tree, node) orelse return .{ .unknown = .unsupported } } };
                };
                return typed(parent, .literal);
            },
            .call => {
                var buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buffer, parent).?; // unreachable: the form is a call's
                if (call.ast.fn_expr == node) return .{ .callee = parent };
                for (call.ast.params, 0..) |each, k| if (each == node) return .{ .argument = .{ .call = parent, .position = k } };
                return .{ .unknown = .unsupported };
            },
            .builtin => {
                var buffer: [2]Ast.Node.Index = undefined;
                for (Facts.builtinArgs(tree, parent, &buffer), 0..) |each, k| if (each == node) return .{ .builtin_argument = .{ .call = parent, .position = k } };
                return .{ .unknown = .unsupported };
            },
            // Its prongs are its own.
            .@"switch" => return if (tree.fullSwitch(parent).?.ast.condition == node) .{ .switched = parent } else .statement, // unreachable: the form is a switch's
            .prong => {
                if (tree.fullSwitchCase(parent).?.ast.target_expr != node) return .{ .matched = parent }; // unreachable: the form is a prong's
                return .{ .carried = .{ .into = model.parentOf(parent) orelse return .{ .unknown = .unsupported }, .how = .prong } };
            },
            .prong_range => return .{ .matched = parent },
            .@"while" => {
                const loop = tree.fullWhile(parent).?; // unreachable: the form is a while's
                if (loop.ast.cond_expr == node) return .{ .tested = parent };
                if (loop.ast.else_expr.unwrap() == node) return .{ .carried = .{ .into = parent, .how = .prong } };
                return .statement;
            },
            .@"for" => {
                const loop = tree.fullFor(parent).?; // unreachable: the form is a for's
                for (loop.ast.inputs, 0..) |each, k| if (each == node) return .{ .looped = .{ .loop = parent, .position = k } };
                if (loop.ast.else_expr.unwrap() == node) return .{ .carried = .{ .into = parent, .how = .prong } };
                return .statement;
            },
            .for_range => return .{ .operand = parent },
            .@"if" => {
                if (tree.fullIf(parent).?.ast.cond_expr == node) return .{ .tested = parent }; // unreachable: the form is an if's
                return .{ .carried = .{ .into = parent, .how = .prong } };
            },
            .@"continue" => return .{ .continued = parent },
            .@"break" => return .{ .carried = .{ .into = breakTarget(tree, model, parent) orelse return .{ .unknown = .unsupported }, .how = .broken } },
            .@"return" => return .{ .returned = parent },
            .grouped => return .{ .carried = .{ .into = parent, .how = .grouped } },
            .@"comptime" => return .{ .carried = .{ .into = parent, .how = .compile_time } },
            .@"nosuspend" => return .{ .carried = .{ .into = parent, .how = .@"nosuspend" } },
            .@"asm" => return .{ .in_asm = parent },
            .frame, .leaf => return .{ .unknown = .unsupported },
        }
    }

    /// What a part of a type expression or a declaration does (`useOf`): which part of which
    /// type or declaration it is, a variable's or field's first value, or a function's body.
    fn declarationUse(tree: *const Ast, model: *const Model, parent: Ast.Node.Index, node: Ast.Node.Index) Use {
        switch (formOf(tree.nodeTag(parent))) {
            .optional_type => return typed(parent, .optional_child),
            .anyframe_type => return typed(parent, .frame_result),
            .merged_errors => return typed(parent, .error_set),
            .error_union => return typed(parent, if (tree.nodeData(parent).node_and_node[0] == node) .error_set else .error_payload),
            .array_type => {
                const array = tree.fullArrayType(parent).?; // unreachable: the form is an array type's
                if (array.ast.elem_type == node) return typed(parent, .array_element);
                return typed(parent, if (array.ast.sentinel.unwrap() == node) .sentinel else .length);
            },
            .pointer_type => {
                const pointer = tree.fullPtrType(parent).?; // unreachable: the form is a pointer type's
                if (pointer.ast.child_type == node) return typed(parent, .pointer_child);
                if (pointer.ast.sentinel.unwrap() == node) return typed(parent, .sentinel);
                if (pointer.ast.align_node.unwrap() == node) return typed(parent, .alignment);
                if (pointer.ast.addrspace_node.unwrap() == node) return typed(parent, .address_space);
                return typed(parent, .bit_range);
            },
            .prototype => {
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, parent).?; // unreachable: the form is a prototype's
                if (proto.ast.return_type.unwrap() == node) return typed(parent, .result);
                if (proto.ast.align_expr.unwrap() == node) return typed(parent, .alignment);
                if (proto.ast.addrspace_expr.unwrap() == node) return typed(parent, .address_space);
                if (proto.ast.section_expr.unwrap() == node) return typed(parent, .section);
                if (proto.ast.callconv_expr.unwrap() == node) return typed(parent, .calling_convention);
                var it = proto.iterate(tree);
                while (it.next()) |param| if (param.type_expr == node) return typed(parent, .parameter);
                return .{ .unknown = .unsupported };
            },
            .fn_decl => return if (tree.nodeData(parent).node_and_node[1] == node) .statement else typed(parent, .signature),
            .variable => {
                const variable = tree.fullVarDecl(parent).?; // unreachable: the form is a variable's
                if (variable.ast.init_node.unwrap() == node) return .{ .initializes = parent };
                if (variable.ast.type_node.unwrap() == node) return typed(parent, .declared);
                if (variable.ast.align_node.unwrap() == node) return typed(parent, .alignment);
                if (variable.ast.addrspace_node.unwrap() == node) return typed(parent, .address_space);
                return typed(parent, .section);
            },
            .field_declaration => {
                const field = model.containerField(tree, parent).?; // unreachable: the form is a field's
                if (field.ast.value_expr.unwrap() == node) return .{ .initializes = parent };
                if (field.ast.type_expr.unwrap() == node) return typed(parent, .declared);
                return typed(parent, .alignment);
            },
            else => return .{ .unknown = .unsupported },
        }
    }

    /// Whether a store's target is `_`, which takes nothing.
    fn discard(tree: *const Ast, node: Ast.Node.Index) bool {
        return tree.nodeTag(node) == .identifier and std.zig.isUnderscore(tree.tokenSlice(tree.nodeMainToken(node)));
    }

    /// What the `break` `jump` leaves: the block, loop or switch its label names, or without
    /// one the innermost loop whose body holds it. Null past the function, or a label not found.
    fn breakTarget(tree: *const Ast, model: *const Model, jump: Ast.Node.Index) ?Ast.Node.Index {
        const label = tree.nodeData(jump).opt_token_and_opt_node[0].unwrap();
        var at = jump;
        while (model.parentOf(at)) |up| : (at = up) {
            const own: ?Ast.TokenIndex, const body: bool = switch (formOf(tree.nodeTag(up))) {
                .fn_decl => return null,
                .body => blk: {
                    const brace = tree.nodeMainToken(up);
                    if (tree.tokenTag(brace) != .l_brace or brace < 2 or tree.tokenTag(brace - 1) != .colon) continue;
                    break :blk .{ brace - 2, false };
                },
                .@"while" => blk: {
                    const loop = tree.fullWhile(up).?; // unreachable: the form is a while's
                    break :blk .{ loop.label_token, loop.ast.then_expr == at or loop.ast.cont_expr.unwrap() == at };
                },
                .@"for" => blk: {
                    const loop = tree.fullFor(up).?; // unreachable: the form is a for's
                    break :blk .{ loop.label_token, loop.ast.then_expr == at };
                },
                .@"switch" => .{ tree.fullSwitch(up).?.label_token, false }, // unreachable: the form is a switch's
                else => continue,
            };
            if (label) |wanted| {
                if (own) |token| if (std.mem.eql(u8, tree.tokenSlice(token), tree.tokenSlice(wanted))) return up;
            } else if (body) return up;
        }
        return null;
    }

    /// The expression whose value `node` gives on whole, the inverse of `Use.carried` for a form
    /// with one operand: parentheses, `.?`, `try`, the payload side of `orelse` and `catch`,
    /// `comptime`, `nosuspend`. Null for any other form.
    pub fn carriedFrom(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
        return switch (formOf(tree.nodeTag(node))) {
            .grouped, .unwrap_optional => tree.nodeData(node).node_and_token[0],
            .tried, .@"comptime", .@"nosuspend" => tree.nodeData(node).node,
            .@"catch", .@"orelse" => tree.nodeData(node).node_and_node[0],
            else => null,
        };
    }

    /// The expressions a value comes from: what `node` gives, through parentheses, `try`, `.?`,
    /// `@as`, `comptime`, `nosuspend`, both sides of `orelse` and `catch`, an `if`'s and a
    /// `switch`'s results, the `break`s a labelled block or `switch` gives, and a loop's `break`s and its
    /// `else` (`Facts.breaksOut`); each one is an expression of none of those forms (a literal, a
    /// name, a call). An exit (`return`, `unreachable`, a `break` or `continue` elsewhere), a
    /// block with no label and an `if` with no `else` (each `void`) give none. Unknown where a
    /// form is not read here, never part of a list.
    pub const Values = union(enum) { leaves: []const Ast.Node.Index, unknown: Facts.Unknown };

    pub fn valuesOf(facts: *Facts, file: Project.FileId, node: Ast.Node.Index) Error!Values {
        const tree = &facts.project.at(file).file.tree;
        if (givesItself(tree, node)) return .{ .leaves = try facts.gpa.dupe(Ast.Node.Index, &.{node}) };
        var leaves: std.ArrayList(Ast.Node.Index) = .empty;
        var work: std.ArrayList(Ast.Node.Index) = .empty;
        try work.append(facts.gpa, node);
        var steps: usize = 0;
        while (work.pop()) |at| {
            steps += 1;
            if (steps > 4096) return .{ .unknown = .budget };
            if (givesItself(tree, at)) {
                try leaves.append(facts.gpa, at);
                continue;
            }
            switch (formOf(tree.nodeTag(at))) {
                .grouped, .unwrap_optional => try work.append(facts.gpa, tree.nodeData(at).node_and_token[0]),
                .tried, .@"comptime", .@"nosuspend" => try work.append(facts.gpa, tree.nodeData(at).node),
                .@"catch", .@"orelse" => try work.appendSlice(facts.gpa, &tree.nodeData(at).node_and_node),
                .@"if" => {
                    const branch = tree.fullIf(at).?; // unreachable: the form is an if's
                    // One with no `else` gives `void`.
                    const otherwise = branch.ast.else_expr.unwrap() orelse continue;
                    try work.append(facts.gpa, branch.ast.then_expr);
                    try work.append(facts.gpa, otherwise);
                },
                // A switch gives each prong's result, and a labeled one each `break` out of it.
                .@"switch" => {
                    for (tree.fullSwitch(at).?.ast.cases) |case| try work.append(facts.gpa, tree.fullSwitchCase(case).?.ast.target_expr); // unreachable: the form is a switch's, its cases are prongs
                    try work.appendSlice(facts.gpa, try facts.breaksOut(file, at));
                },
                .builtin => {
                    if (!Facts.isBuiltin(tree, at, "@as")) {
                        try leaves.append(facts.gpa, at);
                        continue;
                    }
                    var buffer: [2]Ast.Node.Index = undefined;
                    const args = Facts.builtinArgs(tree, at, &buffer);
                    if (args.len != 2) return .{ .unknown = .invalid_front_end };
                    try work.append(facts.gpa, args[1]);
                },
                .body => {
                    // A container's declaration is a type, given whole.
                    var container_buffer: [2]Ast.Node.Index = undefined;
                    if (tree.fullContainerDecl(&container_buffer, at) != null) {
                        try leaves.append(facts.gpa, at);
                        continue;
                    }
                    // A labelled block gives what each `break` that leaves it gives; one with no
                    // label gives `void`.
                    try work.appendSlice(facts.gpa, try facts.breaksOut(file, at));
                },
                .@"return", .@"continue", .@"break" => {},
                // `unreachable` gives none.
                .leaf => {},
                // A loop gives what each `break` out of it gives, and its `else`.
                .@"while", .@"for" => {
                    try work.appendSlice(facts.gpa, try facts.breaksOut(file, at));
                    const otherwise = if (tree.fullFor(at)) |loop| loop.ast.else_expr else tree.fullWhile(at).?.ast.else_expr; // unreachable: the form is a loop's
                    if (otherwise.unwrap()) |value| try work.append(facts.gpa, value);
                },
                .deferred, .variable, .field_declaration, .assign, .compound_assign, .destructure, .prong, .prong_range, .for_range, .fn_decl, .frame, .@"asm" => return .{ .unknown = .unsupported },
                .member, .comparison, .operator, .logic, .concatenation, .address_of, .slice, .deref, .array_access, .array_literal, .struct_literal, .call, .optional_type, .array_type, .pointer_type, .anyframe_type, .error_union, .merged_errors, .prototype => unreachable, // `givesItself`
            }
        }
        return .{ .leaves = leaves.items };
    }

    /// Whether `node` is of no form that chooses or carries a value: its own one value.
    fn givesItself(tree: *const Ast, node: Ast.Node.Index) bool {
        return switch (formOf(tree.nodeTag(node))) {
            .leaf => tree.nodeTag(node) != .unreachable_literal,
            .member, .comparison, .operator, .logic, .concatenation, .address_of, .slice, .deref, .array_access, .array_literal, .struct_literal, .call, .optional_type, .array_type, .pointer_type, .anyframe_type, .error_union, .merged_errors, .prototype => true,
            else => false,
        };
    }

    /// The value the statement `statement` discards: `_ = v`'s `v`; null for any other.
    pub fn discardedBy(facts: *Facts, file: Project.FileId, statement: Ast.Node.Index) Error!?Ast.Node.Index {
        const tree = &facts.project.at(file).file.tree;
        if (formOf(tree.nodeTag(statement)) != .assign) return null;
        const target, const value = tree.nodeData(statement).node_and_node;
        if (try storeInto(facts, file, target) != null or !discard(tree, target)) return null;
        return value;
    }

    /// One step of a place's path (`pathOf`), from the place in toward its root.
    pub const Step = struct {
        /// The node of the place this step reaches: a member read, `@field`, an element, a slice,
        /// `.?`, `.*`, or for the root, the expression the path starts at.
        node: Ast.Node.Index,
        kind: enum { field, index, slice, unwrap, deref, root },
        /// A member's holder's value (`field`).
        holder: ?Facts.Value = null,
        /// A member's name (`field`); null for `@field` with a name it computes, any field of the
        /// holder's type.
        name: ?[]const u8 = null,
        /// The index an element is read at (`index`).
        index: ?Ast.Node.Index = null,
        /// Whether reaching this step's place from the one below crosses a pointer: a member or
        /// element through one, `.*`, an element or slice of a slice.
        crosses: bool = false,
    };

    /// The places a place expression names, from itself in to the root it starts at.
    pub const Path = struct {
        /// The place first, the root last (`.root`).
        steps: []const Step,
        /// The declaration the root names; none where the path starts at a value of its own (a
        /// call's result, a literal, `_`); unknown where a name there does not resolve.
        root: Facts.Named,
    };

    /// The path of the place `node` names, through parentheses, member reads, `@field`, elements,
    /// slices, `.?` and `.*`, to the expression it starts at.
    pub fn pathOf(facts: *Facts, file: Project.FileId, node: Ast.Node.Index) Error!Path {
        const tree = &facts.project.at(file).file.tree;
        var steps: std.ArrayList(Step) = .empty;
        var at = node;
        while (true) switch (tree.nodeTag(at)) {
            .grouped_expression => at = tree.nodeData(at).node_and_token[0],
            .field_access => {
                const holder = tree.nodeData(at).node_and_token[0];
                const value = try facts.resolve(file, holder);
                const name = try Model.identifier(facts.gpa, tree.tokenSlice(tree.nodeData(at).node_and_token[1]));
                try steps.append(facts.gpa, .{ .node = at, .kind = .field, .holder = value, .name = name, .crosses = pointing(value) and !try header(facts, name, value) });
                at = holder;
            },
            .array_access => {
                const holder, const index = tree.nodeData(at).node_and_node;
                try steps.append(facts.gpa, .{ .node = at, .kind = .index, .index = index, .crosses = pointing(try facts.resolve(file, holder)) });
                at = holder;
            },
            .slice_open, .slice, .slice_sentinel => {
                const holder = tree.fullSlice(at).?.ast.sliced; // unreachable: the tag is a slice's
                try steps.append(facts.gpa, .{ .node = at, .kind = .slice, .crosses = pointing(try facts.resolve(file, holder)) });
                at = holder;
            },
            .unwrap_optional => {
                try steps.append(facts.gpa, .{ .node = at, .kind = .unwrap });
                at = tree.nodeData(at).node_and_token[0];
            },
            .deref => {
                try steps.append(facts.gpa, .{ .node = at, .kind = .deref, .crosses = true });
                at = tree.nodeData(at).node;
            },
            else => {
                if (isField(tree, at)) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const args = Facts.builtinArgs(tree, at, &buffer);
                    if (args.len == 2) {
                        const value = try facts.resolve(file, args[0]);
                        const name: ?[]const u8 = switch (try facts.fieldName(file, args[1])) {
                            .name => |spelled| spelled,
                            .each_of, .names, .computed => null,
                        };
                        try steps.append(facts.gpa, .{ .node = at, .kind = .field, .holder = value, .name = name, .crosses = pointing(value) and !try header(facts, name orelse "", value) });
                        at = args[0];
                        continue;
                    }
                }
                try steps.append(facts.gpa, .{ .node = at, .kind = .root });
                const root: Facts.Named = if (tree.nodeTag(at) == .identifier and discard(tree, at)) .none else switch (tree.nodeTag(at)) {
                    .identifier => try facts.definition(file, at),
                    else => .none,
                };
                return .{ .steps = steps.items, .root = root };
            },
        };
    }

    /// Whether `a` and `b` name the same place: one root declaration, and step by step the same
    /// field (by declaration, or by name where neither holder's field resolves: unknown), the
    /// same index (one constant's value, or one name that does not change), `.?` and `.*` alike.
    /// Distinct roots, fields or constant indexes are no where no step crosses a pointer, which
    /// may reach any memory; a union's fields share theirs. What is not shown either way is
    /// unknown, never read by its spelling.
    pub fn samePlace(facts: *Facts, file: Project.FileId, a: Ast.Node.Index, b: Ast.Node.Index) Error!Facts.Is {
        const left = try pathOf(facts, file, a);
        const right = try pathOf(facts, file, b);
        var crosses = false;
        for (left.steps) |step| crosses = crosses or step.crosses;
        for (right.steps) |step| crosses = crosses or step.crosses;
        const differ: Facts.Is = if (crosses) .{ .unknown = .unsupported } else .no;
        const left_root = switch (left.root) {
            .decl => |d| d,
            .none => return .{ .unknown = .unsupported },
            .unknown => |why| return .{ .unknown = why },
        };
        const right_root = switch (right.root) {
            .decl => |d| d,
            .none => return .{ .unknown = .unsupported },
            .unknown => |why| return .{ .unknown = why },
        };
        if (!std.meta.eql(left_root, right_root)) return differ;
        if (left.steps.len != right.steps.len) return differ;
        var verdict: Facts.Is = .yes;
        // From the root out: the step below each is the same place.
        var k = left.steps.len - 1;
        while (k > 0) {
            k -= 1;
            const x = left.steps[k];
            const y = right.steps[k];
            if (x.kind != y.kind) return differ;
            switch (x.kind) {
                .root, .unwrap, .deref => {},
                .slice => verdict = .{ .unknown = .unsupported },
                .field => {
                    const x_name = x.name orelse return .{ .unknown = .unsupported };
                    const y_name = y.name orelse return .{ .unknown = .unsupported };
                    const holder = holderContainer(x.holder.?);
                    if (std.mem.eql(u8, x_name, y_name)) {
                        if (holder == null or facts.member(holder.?, x_name) == null) verdict = .{ .unknown = .unresolved };
                        continue;
                    }
                    // Two fields of a union share its memory; of a type not known, may.
                    if (facts.kindOf(holder orelse return .{ .unknown = .unresolved }) != .keyword_struct) return .{ .unknown = .unsupported };
                    if (crosses) return differ;
                    return .no;
                },
                .index => switch (try sameIndex(facts, file, x.index.?, y.index.?)) {
                    .yes => {},
                    .no => return differ,
                    .unknown => |why| verdict = .{ .unknown = why },
                },
            }
        }
        return verdict;
    }

    /// The container a member's holder is, through pointers and optionals.
    fn holderContainer(value: Facts.Value) ?Facts.Container {
        return switch (value) {
            .container, .instance => |container| container,
            .pointer => |inner| holderContainer(inner.child.*),
            .optional => |inner| holderContainer(inner.*),
            else => null,
        };
    }

    /// Whether two indexes are one value: two integer literals' values, or one parameter or
    /// constant named by both; unknown otherwise.
    fn sameIndex(facts: *Facts, file: Project.FileId, a: Ast.Node.Index, b: Ast.Node.Index) Error!Facts.Is {
        const tree = &facts.project.at(file).file.tree;
        const x = Facts.ungrouped(tree, a);
        const y = Facts.ungrouped(tree, b);
        if (tree.nodeTag(x) == .number_literal and tree.nodeTag(y) == .number_literal) {
            const left = std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(x)));
            const right = std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(y)));
            if (left == .int and right == .int) return if (left.int == right.int) .yes else .no;
            return .{ .unknown = .unsupported };
        }
        const left = switch (try facts.definition(file, x)) {
            .decl => |d| d,
            .none => return .{ .unknown = .unsupported },
            .unknown => |why| return .{ .unknown = why },
        };
        const right = switch (try facts.definition(file, y)) {
            .decl => |d| d,
            .none => return .{ .unknown = .unsupported },
            .unknown => |why| return .{ .unknown = why },
        };
        if (!std.meta.eql(left, right)) return .{ .unknown = .unsupported };
        const record = facts.project.at(left.file).model.declarations[@backingInt(left.index)];
        return switch (record.kind) {
            .parameter => .yes,
            .variable => blk: {
                const declaring = &facts.project.at(left.file).file.tree;
                const variable = declaring.fullVarDecl(record.node) orelse break :blk .{ .unknown = .unsupported };
                break :blk if (declaring.tokenTag(variable.ast.mut_token) == .keyword_const) .yes else .{ .unknown = .unsupported };
            },
            else => .{ .unknown = .unsupported },
        };
    }

    pub const Place = union(enum) {
        /// A variable, a parameter or a capture.
        declaration: Facts.Decl,
        /// A container's field, in every value of the container.
        field: Facts.Decl,
    };

    pub const Kind = enum {
        /// The place's first value: a variable's, a field's default, a literal's `.f = v` making a
        /// value of the container.
        init,
        /// A store of `value` (`x = v`, a destructure's element, a memory builtin's), or of what the
        /// site stores where no one expression is it.
        set,
        /// A store that reads the place first: `x op= v`, `@atomicRmw`.
        update,
        /// Memory written as bytes or by code the program does not hold: a cast's, `extern`'s, an
        /// outside function's given a pointer, `asm`. What it stores is no value the program gives.
        covered,
        /// The place's address taken: `&x`, a slice of an array, a pointer capture over one, a
        /// method's pointer receiver. A pointer that may write the place wherever it goes.
        address,
        /// A read.
        read,
        /// In the open world (`Facts.open_world`), a write by a program the unit is read for:
        /// any value, any function the program may name among them, stored in any way. Its
        /// site is the place's declaration.
        open,
    };

    /// How a site reaches the place a query asks about.
    pub const Reach = enum {
        /// It names the place.
        exact,
        /// It names a member so spelled on a holder whose type does not resolve.
        named,
        /// It stores or reads a whole value of the place's container, or of one that holds it by
        /// value.
        holder,
        /// Its memory does not resolve.
        unresolved,
    };

    pub const Site = struct {
        file: Project.FileId,
        /// The node that accesses: the assignment, the destructure, the literal, the field's
        /// declaration, the builtin call, the call, the `&`, the capture's loop or branch, the read.
        node: Ast.Node.Index,
        /// The expression that names the place at `node`, where one does.
        target: ?Ast.Node.Index = null,
        kind: Kind,
        /// What the place takes, where one expression gives it.
        value: ?Ast.Node.Index = null,
        reach: Reach = .exact,
        /// Part of the place (`x.f` of a struct `x`, `x[i]` of an array), not the whole.
        part: bool = false,
        /// Through a pointer, not by the memory's own name.
        through: bool = false,
        /// Run by a `defer` or an `errdefer`.
        deferred: bool = false,
        /// `@field` with a name computed as the program compiles: any field of the holder's type.
        computed: bool = false,
        /// An update's operation (`update` only): what it combines the place's value with
        /// `value` by.
        operator: ?Update = null,
    };

    /// What an update stores: the place's value combined with the site's by one operation, or
    /// one that does not resolve (an `@atomicRmw` operation it does not name).
    pub const Update = union(enum) { op: Operator, unknown: Facts.Unknown };
    pub const Operator = struct {
        op: enum { add, sub, mul, div, mod, shl, shr, bit_and, bit_or, bit_xor, nand, exchange, max, min },
        /// What an integer past its type's range does: is illegal (`+=`), wraps (`+%=`, an
        /// atomic's arithmetic) or saturates (`+|=`).
        overflow: enum { checked, wrapping, saturating } = .checked,
    };

    /// The operation of a compound assignment's tag.
    fn compound(tag: Ast.Node.Tag) Operator {
        return switch (tag) {
            .assign_mul => .{ .op = .mul },
            .assign_div => .{ .op = .div },
            .assign_mod => .{ .op = .mod },
            .assign_add => .{ .op = .add },
            .assign_sub => .{ .op = .sub },
            .assign_shl => .{ .op = .shl },
            .assign_shl_sat => .{ .op = .shl, .overflow = .saturating },
            .assign_shr => .{ .op = .shr },
            .assign_bit_and => .{ .op = .bit_and },
            .assign_bit_xor => .{ .op = .bit_xor },
            .assign_bit_or => .{ .op = .bit_or },
            .assign_mul_wrap => .{ .op = .mul, .overflow = .wrapping },
            .assign_add_wrap => .{ .op = .add, .overflow = .wrapping },
            .assign_sub_wrap => .{ .op = .sub, .overflow = .wrapping },
            .assign_mul_sat => .{ .op = .mul, .overflow = .saturating },
            .assign_add_sat => .{ .op = .add, .overflow = .saturating },
            .assign_sub_sat => .{ .op = .sub, .overflow = .saturating },
            else => unreachable, // the caller's prong holds the compound assignments alone
        };
    }

    /// The operation an `@atomicRmw` names, by std's own list of them: an atomic's arithmetic
    /// wraps.
    fn atomic(op: std.builtin.AtomicRmwOp) Operator {
        return switch (op) {
            .Xchg => .{ .op = .exchange },
            .Add => .{ .op = .add, .overflow = .wrapping },
            .Sub => .{ .op = .sub, .overflow = .wrapping },
            .And => .{ .op = .bit_and },
            .Nand => .{ .op = .nand },
            .Or => .{ .op = .bit_or },
            .Xor => .{ .op = .bit_xor },
            .Max => .{ .op = .max },
            .Min => .{ .op = .min },
        };
    }

    /// A container by its identity.
    pub const Shape = struct { file: Project.FileId, scope: Model.Scope.Id };
    /// A container reached while collecting, and whether its own memory is written there.
    const Seen = struct { shape: Shape, own: bool };

    const Sites = std.ArrayList(Site);

    /// One file's sites, of writes or of reads.
    pub const File = struct {
        places: std.AutoHashMapUnmanaged(Place, Sites) = .empty,
        /// Stores and reads of a whole value of a container.
        shapes: std.AutoHashMapUnmanaged(Shape, Sites) = .empty,
        /// Members on holders whose type does not resolve, by the member's name.
        named: std.StringHashMapUnmanaged(Sites) = .empty,
        unresolved: Sites = .empty,
        /// Of writes, each store once, by its target: an assignment's, an `op=`'s, a destructure's.
        stores: Sites = .empty,
        /// Of writes, the containers each site stores whole or as bytes through a pointer, by the
        /// site's node.
        through: std.AutoHashMapUnmanaged(Ast.Node.Index, std.ArrayList(Shape)) = .empty,
    };

    /// The run's index, kept in `Facts.memo`.
    const State = struct {
        writes: std.AutoHashMapUnmanaged(Project.FileId, *const File) = .empty,
        /// The files whose writes are being read: a value read meanwhile that needs them waits
        /// for no index (`walking`).
        walked: std.AutoHashMapUnmanaged(Project.FileId, void) = .empty,
        reads: std.AutoHashMapUnmanaged(Project.FileId, *const File) = .empty,
        /// Of each file, the write sites a query for a field of one name reads (`Filter`).
        fields: std.HashMapUnmanaged(Narrow, *const File, Narrow.Context, std.hash_map.default_max_load_percentage) = .empty,
        /// Of each pointer handed to a call, the fields it reaches as a whole value or as bytes.
        handed: std.AutoHashMapUnmanaged(Facts.Key, []const Facts.Decl) = .empty,
    };

    /// What a query for a field needs of a file's writes: the sites whose target or literal
    /// names a member so spelled (resolved, they may be the field's), and with `holders`, every
    /// whole value stored and what code the program does not hold writes. Sites of memory that
    /// does not resolve, casts and `extern`s are read either way. A field's index is built only
    /// of what may name it, so a query does not resolve every store of every file it reads.
    const Filter = struct { name: []const u8, holders: bool };

    const Narrow = struct {
        file: Project.FileId,
        filter: Filter,

        const Context = struct {
            pub fn hash(_: Context, key: Narrow) u64 {
                var h: std.hash.Wyhash = .init(@intFromBool(key.filter.holders));
                h.update(key.filter.name);
                h.update(std.mem.asBytes(&key.file));
                return h.final();
            }
            pub fn eql(_: Context, a: Narrow, b: Narrow) bool {
                return a.file == b.file and a.filter.holders == b.filter.holders and std.mem.eql(u8, a.filter.name, b.filter.name);
            }
        };
    };

    /// What a query needs: for a field, whether the stores of whole values and the writes of
    /// code the program does not hold (`holder` and `covered` sites a function pointer's stores,
    /// which only carry or garble what other stores give, may leave out).
    pub const Need = struct { holders: bool = true };

    pub const Error = Facts.ResolveError;

    /// Each site in `files` that may write `place`: one that names it, and for a field, a member so
    /// named on a holder whose type does not resolve, a whole value stored over its container or
    /// one that holds it by value, and memory that does not resolve. An address taken is a write wherever
    /// the pointer goes, and is among them.
    pub fn writes(facts: *Facts, place: Place, files: []const Project.FileId) Each {
        return writesFor(facts, place, files, .{});
    }

    /// `writes`, of what `need` asks.
    pub fn writesFor(facts: *Facts, place: Place, files: []const Project.FileId, need: Need) Each {
        // A query that keeps whole values and outside code's writes resolves nearly every store
        // of a file: it reads the file's one index, built once, not one of its own per name.
        const of: Each.Of = switch (place) {
            .declaration => .writes,
            .field => if (need.holders) .writes else .field_writes,
        };
        return .{ .facts = facts, .place = place, .files = files, .of = of };
    }

    /// Each site in `files` that may read `place`, as `writes` finds them.
    pub fn reads(facts: *Facts, place: Place, files: []const Project.FileId) Each {
        return .{ .facts = facts, .place = place, .files = files, .of = .reads };
    }

    /// The sites a query finds, read in place from each file's index, built once for the run,
    /// in turn: a query copies none of them, so asking it again and again keeps nothing.
    pub const Each = struct {
        facts: *Facts,
        place: Place,
        files: []const Project.FileId,
        of: Of,
        /// The next file of `files` to read.
        file: usize = 0,
        /// The file being read: its index, and the next site there, counted across its parts
        /// in their order (the part a site is in follows from the count and `ends`).
        index: ?*const File = null,
        at: usize = 0,
        /// How many sites each part held when the file's index was read: the sites the query
        /// gives, as a list made then would hold them.
        ends: [4]usize = @splat(0),
        /// The open world's write (`Kind.open`) is given, after every file's.
        opened: bool = false,

        pub const Of = enum { writes, field_writes, reads };
        /// A file's sites in the order a query reads them: those that name the place, then for
        /// a field or a global, a member so named on an unresolved holder, a whole value of the
        /// container, memory that does not resolve. A local is reached only by its name and the
        /// pointers its address gives.
        const Part = enum { exact, named, holder, unresolved };

        pub fn next(each: *Each) Error!?Site {
            while (true) {
                const index = each.index orelse {
                    if (each.file == each.files.len) {
                        if (each.opened or each.of == .reads or !each.facts.open_world or !each.opensTo()) return null;
                        each.opened = true;
                        const decl = switch (each.place) {
                            inline else => |d| d,
                        };
                        return .{ .file = decl.file, .node = each.record().node, .kind = .open };
                    }
                    const file = each.files[each.file];
                    each.file += 1;
                    each.index = switch (each.of) {
                        .writes => try writesOf(each.facts, file),
                        .field_writes => try fieldWritesOf(each.facts, file, .{ .name = each.record().name, .holders = false }),
                        .reads => try readsOf(each.facts, file),
                    };
                    each.at = 0;
                    for (&each.ends, std.enums.values(Part)) |*end, part| end.* = each.sitesOf(each.index.?, part).len;
                    continue;
                };
                // Read again at each step, up to its length when the index was read: an index
                // another file's reading is still filling may grow, and move, meanwhile.
                var rest = each.at;
                for (each.ends, std.enums.values(Part)) |end, part| {
                    if (rest < end) {
                        each.at += 1;
                        var one = each.sitesOf(index, part)[rest];
                        switch (part) {
                            .exact => {},
                            .named => one.reach = .named,
                            .holder => one.reach = .holder,
                            .unresolved => one.reach = .unresolved,
                        }
                        return one;
                    }
                    rest -= end;
                }
                each.index = null;
            }
        }

        /// Whether a program the unit is read for may write the place (`Facts.open_world`): any
        /// field, of any value it is handed, and a public container-level `var`.
        fn opensTo(each: *const Each) bool {
            const decl = switch (each.place) {
                .field => return true,
                .declaration => |d| d,
            };
            const declared = each.record();
            if (!declared.public or !global(each.facts, decl)) return false;
            const tree = &each.facts.project.at(decl.file).file.tree;
            const variable = tree.fullVarDecl(declared.node) orelse return false;
            return tree.tokenTag(variable.ast.mut_token) == .keyword_var;
        }

        fn record(each: *const Each) Model.Declaration {
            const decl = switch (each.place) {
                inline else => |d| d,
            };
            return each.facts.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        }

        fn sitesOf(each: *const Each, index: *const File, part: Part) []const Site {
            const decl = switch (each.place) {
                inline else => |d| d,
            };
            const local = each.place == .declaration and !global(each.facts, decl);
            const found: ?Sites = switch (part) {
                .exact => index.places.get(each.place),
                .named => if (local) null else index.named.get(each.record().name),
                .holder => if (each.place == .field) index.shapes.get(.{ .file = decl.file, .scope = each.record().scope }) else null,
                .unresolved => if (local) null else index.unresolved,
            };
            return if (found) |list| list.items else &.{};
        }
    };

    /// Whether a declaration lives outside any function: in a file's or a container's scope.
    pub fn global(facts: *Facts, decl: Facts.Decl) bool {
        const model = &facts.project.at(decl.file).model;
        const record = model.declarations[@backingInt(decl.index)];
        return switch (model.scopes[@backingInt(record.scope)].kind) {
            .file, .container => true,
            else => false,
        };
    }

    /// Each store in `file`, once, by its target: `x = v`, `x op= v`, a destructure's target
    /// (with its element where the value is a literal).
    pub fn storesIn(facts: *Facts, file: Project.FileId) Error![]const Site {
        return (try writesOf(facts, file)).stores.items;
    }

    /// The fields the write at `node` stores through a pointer as part of a whole value or of
    /// its bytes, each container's that the memory written holds by value (`h.* = other`,
    /// `@memcpy(std.mem.asBytes(h), bytes)`, `std.mem.asBytes(h)[0] = b`): memory the place's
    /// other names read. A field the store names is a site of its own, not among them.
    pub fn fieldsThrough(facts: *Facts, file: Project.FileId, node: Ast.Node.Index) Error![]const Facts.Decl {
        const shapes_written = (try writesOf(facts, file)).through.get(node) orelse return &.{};
        return fieldsOfShapes(facts, shapes_written.items);
    }

    /// Whether the function declaring `param` may write the memory the parameter points at,
    /// by its mentions (the model's references; no walk is read): through a place in that
    /// memory (`b[0] = v`, `p.f += 1`, `&p.f`, a slice of it, a method called on a part of it),
    /// or with the pointer itself handed on, stored, returned, ranged over or its address taken.
    /// A value read out of the memory (`b[i]`, `p.f` copied, `b.len`) writes nothing, nor the
    /// parameter compared or tested.
    pub fn writtenThrough(facts: *Facts, param: Facts.Decl) Error!bool {
        const tree = &facts.project.at(param.file).file.tree;
        const model = &facts.project.at(param.file).model;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const mention: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const reference = model.reference(mention) orelse continue;
            if (reference.declaration != param.index) continue;
            // `at` is the pointer itself (or what carries it on) until a step reaches a place in
            // the memory it points at.
            var at = mention;
            var place = false;
            for (0..32) |_| {
                // A store's side is read by its assignment, not by its site (`useOf` finds the
                // site in the file's walk, which may be the walk asking this).
                if (model.parentOf(at)) |parent| switch (formOf(tree.nodeTag(parent))) {
                    .assign, .compound_assign, .destructure => |form| {
                        const target = switch (form) {
                            .destructure => tree.assignDestructure(parent).ast.value_expr != at,
                            else => tree.nodeData(parent).node_and_node[0] == at,
                        };
                        if (target) {
                            if (place) return true;
                            // The parameter itself given a new value writes no memory it points at.
                            if (at == mention) break;
                            return true;
                        }
                        // A value read out of the memory, or the pointer given to `_`, an
                        // operand of `op=`: no write. The pointer itself stored or destructured
                        // goes on where this function does not follow it.
                        if (place or form == .compound_assign) break;
                        if (form == .assign and discard(tree, tree.nodeData(parent).node_and_node[0])) break;
                        return true;
                    },
                    else => {},
                };
                switch (try useOf(facts, param.file, at)) {
                    .member, .element, .dereferenced => |access| {
                        at = access;
                        place = true;
                    },
                    // A slice of a place in the memory points into it, as the pointer does.
                    .sliced => |access| {
                        at = access;
                        place = false;
                    },
                    .carried => |carried| switch (carried.how) {
                        .grouped, .unwrapped, .tried, .compile_time, .@"nosuspend" => at = carried.into,
                        else => return true,
                    },
                    .written, .updated, .address, .callee => {
                        if (place) return true;
                        // The parameter itself given a new value writes no memory it points at.
                        if (at == mention) break;
                        return true;
                    },
                    .argument, .builtin_argument, .returned, .stored, .initializes, .looped, .element_of, .field_of, .destructured => {
                        if (place) break;
                        return true;
                    },
                    .unknown => return true,
                    else => break,
                }
            } else return true;
        }
        return false;
    }

    /// The values a local variable is given by its own name, read by its mentions (the model's
    /// references; no walk is read): its initializer's, and each `x = v`'s `v`. A local is
    /// reached only by its name and the pointers its address gives, so a mention that reads it
    /// gives it nothing, nor one that reaches other memory through a pointer it holds
    /// (`x.* = v`, `x[i] = v` of a slice, `x.f.* = v`). Null where one may change it otherwise:
    /// a store to a part of it (`x.f = v`, `@field(x, n) = v`, `x.? = v`), an `op=`, a
    /// destructure's target, its address or a part's (but dropped, `_ = &x`), a slice of its own
    /// memory, a method called on it or a part of it, a capture by pointer of it, an `asm`
    /// operand, a use not read.
    pub fn givenByName(facts: *Facts, decl: Facts.Decl) Error!?[]const Facts.Key {
        const kept_by = try facts.memo(GivenByName);
        if (kept_by.found.get(decl)) |kept| return kept;
        const found = try storedFrom(facts, decl);
        // What a resolve the budget refused gave is not kept, as `resolve` keeps none.
        if (facts.remaining != 0) try kept_by.found.put(facts.gpa, decl, found);
        return found;
    }

    const GivenByName = struct {
        found: std.AutoHashMapUnmanaged(Facts.Decl, ?[]const Facts.Key) = .empty,
        /// Each file's mentions by the declaration they name, built once.
        mentions: std.AutoHashMapUnmanaged(Project.FileId, std.AutoHashMapUnmanaged(Model.Declaration.Id, std.ArrayList(Ast.Node.Index))) = .empty,
    };

    /// The nodes in `file` that name each of its declarations (the model's references).
    fn mentionsIn(facts: *Facts, file: Project.FileId) Error!*const std.AutoHashMapUnmanaged(Model.Declaration.Id, std.ArrayList(Ast.Node.Index)) {
        const kept_by = try facts.memo(GivenByName);
        const entry = try kept_by.mentions.getOrPut(facts.gpa, file);
        if (entry.found_existing) return entry.value_ptr;
        entry.value_ptr.* = .empty;
        for (facts.project.at(file).model.references) |reference| {
            const d = reference.declaration orelse continue;
            const list = try entry.value_ptr.getOrPut(facts.gpa, d);
            if (!list.found_existing) list.value_ptr.* = .empty;
            try list.value_ptr.append(facts.gpa, reference.node);
        }
        return entry.value_ptr;
    }

    fn storedFrom(facts: *Facts, decl: Facts.Decl) Error!?[]const Facts.Key {
        const tree = &facts.project.at(decl.file).file.tree;
        const model = &facts.project.at(decl.file).model;
        var out: std.ArrayList(Facts.Key) = .empty;
        const record = model.declarations[@backingInt(decl.index)];
        if ((tree.fullVarDecl(record.node) orelse return null).ast.init_node.unwrap()) |init| try out.append(facts.gpa, .{ .file = decl.file, .node = init });
        const mentions = if ((try mentionsIn(facts, decl.file)).get(decl.index)) |list| list.items else &.{};
        for (mentions) |mention| {
            // `at` is the variable's own memory, the whole or a part, until a step crosses a
            // pointer it holds: past one nothing written is the variable.
            var at = mention;
            for (0..32) |_| {
                // A store's side is read by its assignment, not by its site (`useOf` finds the
                // site in the file's walk, which may be the walk asking this).
                if (model.parentOf(at)) |parent| switch (formOf(tree.nodeTag(parent))) {
                    .assign, .compound_assign, .destructure => |form| {
                        const target = switch (form) {
                            .destructure => tree.assignDestructure(parent).ast.value_expr != at,
                            else => tree.nodeData(parent).node_and_node[0] == at,
                        };
                        if (!target) break;
                        if (form != .assign or at != mention) return null;
                        try out.append(facts.gpa, .{ .file = decl.file, .node = tree.nodeData(parent).node_and_node[1] });
                        break;
                    },
                    else => {},
                };
                switch (try useOf(facts, decl.file, at)) {
                    .member, .element, .dereferenced, .sliced => |access| {
                        if ((try pathOf(facts, decl.file, access)).steps[0].crosses) break;
                        // A slice of its own memory points into it.
                        if (tree.fullSlice(access) != null) return null;
                        at = access;
                    },
                    .builtin_argument => |argument| {
                        if (!isField(tree, argument.call) or argument.position != 0) break;
                        if ((try pathOf(facts, decl.file, argument.call)).steps[0].crosses) break;
                        at = argument.call;
                    },
                    .carried => |carried| switch (carried.how) {
                        .grouped, .unwrapped, .tried, .compile_time, .@"nosuspend" => at = carried.into,
                        else => break,
                    },
                    .address => |access| {
                        if (at == mention and droppedAddress(tree, model, access)) break;
                        return null;
                    },
                    // A method of its own or of a part's: its receiver may be the address.
                    .callee => if (at == mention) break else return null,
                    // A capture by pointer of its own memory (not of what a slice of it points at).
                    .looped => |loop| if (pointerCapture(tree, loop.loop, loop.position) and !pointing(try facts.resolve(decl.file, at))) return null else break,
                    .tested, .switched => |holder| if (pointerCapture(tree, holder, null) and !pointing(try facts.resolve(decl.file, at))) return null else break,
                    .written, .updated, .in_asm, .unknown => return null,
                    else => break,
                }
            } else return null;
        }
        return out.items;
    }

    /// Whether `_ = &x` drops the address `access` takes.
    fn droppedAddress(tree: *const Ast, model: *const Model, access: Ast.Node.Index) bool {
        const parent = model.parentOf(access) orelse return false;
        if (tree.nodeTag(parent) != .assign) return false;
        const lhs, const rhs = tree.nodeData(parent).node_and_node;
        return rhs == access and discard(tree, lhs);
    }

    /// Whether `holder` (a `for`, an `if`, a `while`, a `switch`) captures by pointer: the `for`'s
    /// capture at `position`; the `if`'s or `while`'s payload; any prong's of the `switch`.
    fn pointerCapture(tree: *const Ast, holder: Ast.Node.Index, position: ?usize) bool {
        if (tree.fullFor(holder)) |loop| {
            var at = loop.payload_token;
            var here: usize = 0;
            while (tree.tokenTag(at) != .pipe) : (at += 1) switch (tree.tokenTag(at)) {
                .comma => here += 1,
                .asterisk => if (position == null or position.? == here) return true,
                else => {},
            };
            return false;
        }
        if (tree.fullIf(holder)) |branch| return if (branch.payload_token) |token| tree.tokenTag(token) == .asterisk else false;
        if (tree.fullWhile(holder)) |loop| return if (loop.payload_token) |token| tree.tokenTag(token) == .asterisk else false;
        if (tree.fullSwitch(holder)) |choice| for (choice.ast.cases) |case| {
            const token = tree.fullSwitchCase(case).?.payload_token orelse continue; // unreachable: a switch's case
            if (tree.tokenTag(token) == .asterisk) return true;
        };
        return false;
    }

    /// The fields a call may write through `pointer`, an argument it is handed, as a store
    /// through it writes them (`fieldsThrough`): each container's the memory it points at holds
    /// by value, where it reaches that memory through a pointer or as another type
    /// (`r.readSliceAll(std.mem.asBytes(h))`, a helper's `put(std.mem.asBytes(h))`). A pointer
    /// to a place reached by its own name (`&x`) reaches no field but the place's.
    pub fn fieldsHanded(facts: *Facts, file: Project.FileId, pointer: Ast.Node.Index) Error![]const Facts.Decl {
        const state = try facts.memo(State);
        const key: Facts.Key = .{ .file = file, .node = pointer };
        if (state.handed.get(key)) |kept| return kept;
        const index = try facts.gpa.create(File);
        index.* = .{};
        var walk: Walk = .{ .facts = facts, .file = file, .index = index };
        try walk.pointee(walk.make(pointer, pointer, .covered, null));
        const fields = if (index.through.get(pointer)) |shapes_reached| try fieldsOfShapes(facts, shapes_reached.items) else &.{};
        try state.handed.put(facts.gpa, key, fields);
        return fields;
    }

    /// The fields of each container `shapes_held` names.
    fn fieldsOfShapes(facts: *Facts, shapes_held: []const Shape) Error![]const Facts.Decl {
        var out: std.ArrayList(Facts.Decl) = .empty;
        for (shapes_held) |held_shape| {
            const model = &facts.project.at(held_shape.file).model;
            for (model.declarations, 0..) |record, d| {
                if (record.kind != .field or record.scope != held_shape.scope) continue;
                try out.append(facts.gpa, .{ .file = held_shape.file, .index = @fromBackingInt(@intCast(d)) });
            }
        }
        return out.items;
    }

    /// The write sites of `file`, found the first time a query reaches it.
    pub fn writesOf(facts: *Facts, file: Project.FileId) Error!*const File {
        const state = try facts.memo(State);
        if (state.writes.get(file)) |kept| return kept;
        const index = try facts.gpa.create(File);
        index.* = .{};
        var walk: Walk = .{ .facts = facts, .file = file, .index = index };
        try state.walked.put(facts.gpa, file, {});
        walk.writes() catch |err| {
            _ = state.walked.remove(file);
            return err;
        };
        // The file's stores are known: what a `var` holds may now be read from them.
        try state.writes.put(facts.gpa, file, index);
        _ = state.walked.remove(file);
        try walk.settle();
        if (facts.check_records) |check| try check.accesses(facts, file, index, "writes");
        return index;
    }

    /// Whether `file`'s writes are being read, so a query for them now would read them again.
    pub fn walking(facts: *Facts, file: Project.FileId) Error!bool {
        return (try facts.memo(State)).walked.contains(file);
    }

    /// The write sites of `file` a query for a field `filter` names needs, found once.
    fn fieldWritesOf(facts: *Facts, file: Project.FileId, filter: Filter) Error!*const File {
        const state = try facts.memo(State);
        const key: Narrow = .{ .file = file, .filter = filter };
        if (state.fields.get(key)) |kept| return kept;
        const index = try facts.gpa.create(File);
        index.* = .{};
        var walk: Walk = .{ .facts = facts, .file = file, .index = index, .filter = filter };
        try walk.writes();
        try walk.settle();
        try state.fields.put(facts.gpa, key, index);
        return index;
    }

    /// The read sites of `file`, found the first time a query reaches it.
    pub fn readsOf(facts: *Facts, file: Project.FileId) Error!*const File {
        const state = try facts.memo(State);
        if (state.reads.get(file)) |kept| return kept;
        const index = try facts.gpa.create(File);
        index.* = .{};
        var walk: Walk = .{ .facts = facts, .file = file, .index = index };
        try walk.reads();
        try state.reads.put(facts.gpa, file, index);
        if (facts.check_records) |check| try check.accesses(facts, file, index, "reads");
        return index;
    }

    const BuiltinStore = struct { pointer: usize, kind: Kind, value: ?usize };
    /// The memory builtins that write through a pointer: the argument that is the pointer, the
    /// store's kind, and the argument it stores where one does.
    const writer_builtins = [_]struct { []const u8, BuiltinStore }{
        .{ "@memcpy", .{ .pointer = 0, .kind = .set, .value = null } },
        .{ "@memmove", .{ .pointer = 0, .kind = .set, .value = null } },
        .{ "@memset", .{ .pointer = 0, .kind = .set, .value = 1 } },
        .{ "@atomicStore", .{ .pointer = 1, .kind = .set, .value = 2 } },
        .{ "@atomicRmw", .{ .pointer = 1, .kind = .update, .value = 3 } },
        .{ "@cmpxchgWeak", .{ .pointer = 1, .kind = .set, .value = 3 } },
        .{ "@cmpxchgStrong", .{ .pointer = 1, .kind = .set, .value = 3 } },
    };
    /// The memory builtins that read through a pointer, by the argument that is the pointer.
    const reader_builtins = [_]struct { []const u8, usize }{
        .{ "@memcpy", 1 },    .{ "@memmove", 1 },     .{ "@atomicLoad", 1 },
        .{ "@atomicRmw", 1 }, .{ "@cmpxchgWeak", 1 }, .{ "@cmpxchgStrong", 1 },
    };

    /// A copy of memory: what it writes and what it reads; where `exchange`, each side is also
    /// written with what the other held (a swap, which duplicates nothing).
    pub const Copy = struct { into: Side, from: Side, exchange: bool = false };

    /// One side of a copy: the place its pointer points at (`pointed`), or where that names
    /// none, the pointer through its views (`viewed`), whose pointee no place here names; or a
    /// value the copy makes or stores (`std.mem.bytesToValue(T, b)`'s result, what `raw.* = v`
    /// stores through a cast).
    pub const Side = union(enum) {
        place: Ast.Node.Index,
        pointer: Ast.Node.Index,
        value: Ast.Node.Index,

        pub fn node(self: Side) Ast.Node.Index {
            return switch (self) {
                inline else => |n| n,
            };
        }
    };

    /// The copy of memory `node` makes, by what it does: a builtin that writes through one
    /// pointer what it reads through another (`@memcpy`, `@memmove`); a call of a function that
    /// does (`Facts.copierOf`: `std.mem.copyForwards`, `std.mem.swap`), or that stores a value
    /// it is given through a pointer that reinterprets the memory (`std.mem.writeInt` into
    /// `std.mem.asBytes(&d)[0..12]`, a setter handed `@ptrCast(&d)`); a value read out of other
    /// memory as another type, through a pointer that reinterprets it (`std.mem.asBytes(&k).*`,
    /// `std.mem.bytesAsSlice(T, b)[0]`) or a call of a function that reads one out
    /// (`Facts.readOf`: `std.mem.bytesToValue`, `toBytes`, `readInt`; a getter handed a
    /// reinterpreting pointer); a store through such a pointer (`raw.* = v` with
    /// `raw = @ptrCast(&d)`, `std.mem.asBytes(&d)[0] = b`). A place a store writes is not read.
    pub fn copyAt(facts: *Facts, file: Project.FileId, node: Ast.Node.Index) Error!?Copy {
        const tree = &facts.project.at(file).file.tree;
        switch (tree.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
            .call_one, .call_one_comma, .call, .call_comma => return copyByCall(facts, file, node),
            .deref, .array_access => {
                if (stored(facts, file, node)) return null;
                const pointer = if (tree.nodeTag(node) == .deref) tree.nodeData(node).node else tree.nodeData(node).node_and_node[0];
                // An element of an array held by value is its own memory, not read through one.
                if (tree.nodeTag(node) == .array_access and !try pointerArgument(facts, file, pointer)) return null;
                if (!try reinterprets(facts, file, pointer)) return null;
                return .{ .into = .{ .value = node }, .from = try sideOf(facts, file, pointer) };
            },
            .assign => {
                const target, const value = tree.nodeData(node).node_and_node;
                const pointer = try crossed(facts, file, target) orelse return null;
                if (!try reinterprets(facts, file, pointer)) return null;
                return .{ .into = try sideOf(facts, file, pointer), .from = try storedSide(facts, file, value) };
            },
            else => return null,
        }
        const name = tree.tokenSlice(tree.nodeMainToken(node));
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        const into = for (writer_builtins) |entry| {
            if (std.mem.eql(u8, name, entry[0]) and entry[1].value == null and entry[1].kind == .set) break entry[1].pointer;
        } else return null;
        const from = for (reader_builtins) |entry| {
            if (std.mem.eql(u8, name, entry[0])) break entry[1];
        } else return null;
        if (into >= args.len or from >= args.len) return null;
        return .{ .into = try sideOf(facts, file, args[into]), .from = try sideOf(facts, file, args[from]) };
    }

    /// The copy a call makes: a copier's, from one argument's memory into another's, or of a
    /// value into memory its pointer reads as another type; a reader's, its result read out of
    /// an argument's memory, as another type by the reader or by the pointer it is handed.
    fn copyByCall(facts: *Facts, file: Project.FileId, node: Ast.Node.Index) Error!?Copy {
        const call = (try calls.at(facts, file, node)) orelse return null;
        const args = switch (call.args) {
            .known => |each| each,
            .unknown => return null,
        };
        const functions: []const Facts.Decl = switch (call.callee) {
            .function => |function| &.{function},
            .choice => |each| each,
            .any => return null,
        };
        var copier: ?Facts.Copier = null;
        var reader: ?Facts.Reader = null;
        for (functions, 0..) |function, k| {
            const one = try facts.copierOf(function);
            const read = try facts.readOf(function);
            if (k == 0) {
                copier = one;
                reader = read;
                continue;
            }
            if (copier) |c| if (one == null or !std.meta.eql(one.?, c)) {
                copier = null;
            };
            if (reader) |r| if (read == null or !std.meta.eql(read.?, r)) {
                reader = null;
            };
        }
        if (copier) |c| if (c.into < args.len and c.from < args.len and try pointerArgument(facts, file, args[c.into])) {
            // Memory copied between what two pointers point at.
            if (try pointerArgument(facts, file, args[c.from])) return .{ .into = try sideOf(facts, file, args[c.into]), .from = try sideOf(facts, file, args[c.from]), .exchange = c.exchange };
            // A value stored through a pointer that reads the memory as another type; one
            // stored as the memory's own is a store, as any argument passed is a copy.
            if (!c.exchange and try reinterprets(facts, file, args[c.into])) return .{ .into = try sideOf(facts, file, args[c.into]), .from = .{ .value = args[c.from] } };
        };
        if (reader) |r| if (r.from < args.len) {
            const recast = r.recast or (try pointerArgument(facts, file, args[r.from]) and try reinterprets(facts, file, args[r.from]));
            if (recast) return .{ .into = .{ .value = node }, .from = try readSide(facts, file, args[r.from]) };
        };
        return null;
    }

    /// What a value a store writes gives a copy: memory read as another type where it is a
    /// `for`'s capture by value over a pointer that reinterprets it (`|s|` over
    /// `std.mem.asBytes(&g)` reads `g`'s bytes, as `std.mem.asBytes(&g)[i]` does); else the
    /// value itself.
    fn storedSide(facts: *Facts, file: Project.FileId, value: Ast.Node.Index) Error!Side {
        const tree = &facts.project.at(file).file.tree;
        const model = &facts.project.at(file).model;
        const named = Facts.ungrouped(tree, value);
        if (tree.nodeTag(named) != .identifier) return .{ .value = value };
        const d = (model.reference(named) orelse return .{ .value = value }).declaration orelse return .{ .value = value };
        const record = model.declarations[@backingInt(d)];
        if (record.kind != .capture or tree.fullFor(record.node) == null or (record.token > 0 and tree.tokenTag(record.token - 1) == .asterisk)) return .{ .value = value };
        const input = facts.captureSource(file, record) orelse return .{ .value = value };
        if (!try pointerArgument(facts, file, input) or !try reinterprets(facts, file, input)) return .{ .value = value };
        return sideOf(facts, file, input);
    }

    /// Whether a call's argument is a pointer: its value resolves to one, or it keeps one (a
    /// cast or a view of a pointer, `viewed`: `@ptrCast(d)` handed to a `*T` whose type comes
    /// from where it goes).
    fn pointerArgument(facts: *Facts, file: Project.FileId, arg: Ast.Node.Index) Error!bool {
        if (pointing(try facts.resolve(file, arg))) return true;
        const memory = try viewed(facts, file, arg);
        return memory != arg and pointing(try facts.resolve(file, memory));
    }

    /// Whether `node` is the place an assignment stores into, which it does not read.
    fn stored(facts: *Facts, file: Project.FileId, node: Ast.Node.Index) bool {
        const tree = &facts.project.at(file).file.tree;
        const parent = facts.project.at(file).model.parentOf(node) orelse return false;
        return tree.nodeTag(parent) == .assign and tree.nodeData(parent).node_and_node[0] == node;
    }

    /// What a reader's argument gives it: memory it points at, or a value it reads the bytes of
    /// (`std.mem.toBytes(x)` reads `x`).
    fn readSide(facts: *Facts, file: Project.FileId, arg: Ast.Node.Index) Error!Side {
        if (try pointerArgument(facts, file, arg)) return sideOf(facts, file, arg);
        return .{ .place = arg };
    }

    /// The pointer a store into `target` writes through, the first its path crosses
    /// (`raw.*`'s `raw`, `std.mem.asBytes(j)[0]`'s view): none where it names its memory.
    fn crossed(facts: *Facts, file: Project.FileId, target: Ast.Node.Index) Error!?Ast.Node.Index {
        const tree = &facts.project.at(file).file.tree;
        var at = target;
        for (0..16) |_| switch (tree.nodeTag(at)) {
            .grouped_expression, .unwrap_optional => at = tree.nodeData(at).node_and_token[0],
            .deref => return tree.nodeData(at).node,
            .array_access, .field_access => {
                const holder = if (tree.nodeTag(at) == .array_access) tree.nodeData(at).node_and_node[0] else tree.nodeData(at).node_and_token[0];
                if (pointing(try facts.resolve(file, holder))) return holder;
                at = holder;
            },
            else => return null,
        };
        return null;
    }

    /// Whether `pointer` reads or writes other memory as another type: a view or a cast of it
    /// whose pointee is not the memory's own type (`@ptrCast(&d)` as a `*i96`,
    /// `std.mem.asBytes(&k)`). A type that does not resolve may be another.
    pub fn reinterprets(facts: *Facts, file: Project.FileId, pointer: Ast.Node.Index) Error!bool {
        const tree = &facts.project.at(file).file.tree;
        const memory = try viewed(facts, file, pointer);
        // The pointer as itself: through the names that hold it and the values chosen as it
        // (`try a.alloc(T, n)`, an `if`'s branches), none of which reads memory as another type.
        // Where that reaches the memory, no cast or view lies between them.
        if (memory == try viewedFrom(facts, file, pointer, 0, .itself)) return false;
        const given = try facts.resolve(file, pointer);
        // What the memory is: a place's own type, or what the pointer it is reached by points at.
        const own: Facts.Value = switch (tree.nodeTag(memory)) {
            .address_of => try facts.resolve(file, tree.nodeData(memory).node),
            else => switch (try facts.resolve(file, memory)) {
                .pointer => |inner| inner.child.*,
                else => |other| other,
            },
        };
        const seen: Facts.Value = switch (given) {
            .pointer => |inner| inner.child.*,
            else => return true,
        };
        if (!seen.known() or !own.known()) return true;
        return !Facts.same(seen, own, 0);
    }

    /// The side a pointer a builtin writes or reads through is: the place it points at, or itself
    /// through its views.
    pub fn sideOf(facts: *Facts, file: Project.FileId, pointer: Ast.Node.Index) Error!Side {
        if (try pointed(facts, file, pointer)) |place| return .{ .place = place };
        return .{ .pointer = try viewed(facts, file, pointer) };
    }

    /// The pointer whose memory `pointer` points at, through what keeps it: the casts that keep
    /// an address (`throughCasts`), a slice of a pointer, a name holding a pointer (`heldPointer`:
    /// `const b = std.mem.asBytes(j); b[0] = v` writes through what `j` points at), each value an
    /// `if`, a `switch`, a labeled block, `orelse` or `catch` chooses where all point into the
    /// same memory (`valuesOf`), and each call of a view (`viewOf`), the argument it is a view
    /// of (`std.mem.asBytes(&x)` points at what `&x` does). A call of a choice of functions is
    /// followed where each is a view of the same argument.
    pub fn viewed(facts: *Facts, file: Project.FileId, pointer: Ast.Node.Index) Error!Ast.Node.Index {
        return viewedFrom(facts, file, pointer, 0, .views);
    }

    /// Which steps `viewedFrom` takes: every one that keeps the address (`views`), or only those
    /// that keep the pointer as itself too (`itself`: the names that hold it and the values
    /// chosen as it; no cast, slice or view, which may read the memory as another type).
    const Steps = enum { views, itself };

    fn viewedFrom(facts: *Facts, file: Project.FileId, pointer: Ast.Node.Index, depth: u8, steps: Steps) Error!Ast.Node.Index {
        const tree = &facts.project.at(file).file.tree;
        var at = pointer;
        for (0..16) |_| {
            if (steps == .views) at = try facts.throughCasts(file, at);
            switch (tree.nodeTag(at)) {
                .identifier => {
                    at = try heldPointer(facts, file, at, depth, steps) orelse return at;
                    continue;
                },
                // A slice of an array is the array's memory: its place (`pointed`).
                .slice_open, .slice, .slice_sentinel => {
                    if (steps == .itself) return at;
                    const base = tree.fullSlice(at).?.ast.sliced; // unreachable: the tag is a slice's
                    if (!pointing(try facts.resolve(file, base))) return at;
                    at = base;
                    continue;
                },
                else => {},
            }
            var buffer: [1]Ast.Node.Index = undefined;
            if (tree.fullCall(&buffer, at) == null) {
                const leaves = switch (try valuesOf(facts, file, at)) {
                    .leaves => |each| each,
                    .unknown => return at,
                };
                if (leaves.len == 0 or (leaves.len == 1 and leaves[0] == at)) return at;
                const memory = try sameMemory(facts, file, leaves, depth, steps) orelse return at;
                // A choice that ends at a leaf of its own names no more than it does, and keeps
                // its type: past `try`, `.?`, `orelse` or `catch` (`try a.alloc(T, n)`) the leaf's
                // own value is the error union or the optional, not the pointer. A place's address
                // names the place.
                if (tree.nodeTag(memory) != .address_of and std.mem.findScalar(Ast.Node.Index, leaves, memory) != null) return at;
                at = memory;
                continue;
            }
            if (steps == .itself) return at;
            const call = (try calls.at(facts, file, at)) orelse return at;
            const args = switch (call.args) {
                .known => |each| each,
                .unknown => return at,
            };
            const viewing = switch (call.callee) {
                .function => |function| try facts.viewOf(function) orelse return at,
                .choice => |each| try sameView(facts, each) orelse return at,
                .any => return at,
            };
            if (viewing >= args.len) return at;
            at = args[viewing];
        }
        return at;
    }

    /// The pointer a name holds, the same address wherever it is read: a variable's one value,
    /// or each it is given where all point into the same memory (`givenTo`: a constant's
    /// initializer; a `var` no store, nor its address, may change otherwise); a `for`'s capture
    /// by pointer, into the input at its position (`|*d|` over `std.mem.asBytes(j)` points into
    /// what `j` does). Null for any other name.
    fn heldPointer(facts: *Facts, file: Project.FileId, name: Ast.Node.Index, depth: u8, steps: Steps) Error!?Ast.Node.Index {
        const tree = &facts.project.at(file).file.tree;
        const model = &facts.project.at(file).model;
        const d = (model.reference(name) orelse return null).declaration orelse return null;
        const record = model.declarations[@backingInt(d)];
        switch (record.kind) {
            .variable => {
                // Read as a pointer by every caller (a pointer a store, a copy or a view goes
                // through): a name so read holds one, and Zig compiles no store through one that
                // does not. Its type is not resolved again at each use.
                if (global(facts, .{ .file = file, .index = d })) return null;
                const given = (try facts.givenTo(.{ .file = file, .index = d }, false)) orelse return null;
                if (given.len == 1) return if (given[0].file == file) given[0].node else null;
                var nodes: std.ArrayList(Ast.Node.Index) = .empty;
                for (given) |key| {
                    if (key.file != file) return null;
                    try nodes.append(facts.gpa, key.node);
                }
                return switch (nodes.items.len) {
                    0 => null,
                    1 => nodes.items[0],
                    else => try sameMemory(facts, file, nodes.items, depth, steps),
                };
            },
            .capture => {
                if (tree.fullFor(record.node) == null or record.token == 0 or tree.tokenTag(record.token - 1) != .asterisk) return null;
                return facts.captureSource(file, record);
            },
            else => return null,
        }
    }

    /// The memory each of `pointers` points into, where it is one: each read through `viewed`
    /// to the same node, the same place's address, or the same place (`samePlace`). Null where
    /// any differs or is not shown the same.
    fn sameMemory(facts: *Facts, file: Project.FileId, pointers: []const Ast.Node.Index, depth: u8, steps: Steps) Error!?Ast.Node.Index {
        if (depth >= 8) return null;
        const tree = &facts.project.at(file).file.tree;
        const first = try viewedFrom(facts, file, pointers[0], depth + 1, steps);
        for (pointers[1..]) |each| {
            const other = try viewedFrom(facts, file, each, depth + 1, steps);
            if (other == first) continue;
            const both = tree.nodeTag(first) == .address_of and tree.nodeTag(other) == .address_of;
            if (both) {
                if (try samePlace(facts, file, tree.nodeData(first).node, tree.nodeData(other).node) != .yes) return null;
                continue;
            }
            if (tree.nodeTag(first) == .address_of or tree.nodeTag(other) == .address_of) return null;
            if (try samePlace(facts, file, first, other) != .yes) return null;
        }
        return first;
    }

    /// The root of `place`, where it is a part of what a pointer root points at: the root's
    /// pointer is the one step that crosses one (`p.bytes`, `p.*`, `p.a[1]` with `p` a pointer
    /// and `a` an array). Null where no step crosses, or one past the root's does (`p.next.*`:
    /// other memory).
    pub fn pointeeRoot(facts: *Facts, file: Project.FileId, place: Ast.Node.Index) Error!?Ast.Node.Index {
        const steps = (try pathOf(facts, file, place)).steps;
        if (steps.len < 2 or steps[steps.len - 1].kind != .root or !steps[steps.len - 2].crosses) return null;
        for (steps[0 .. steps.len - 2]) |step| if (step.crosses) return null;
        return steps[steps.len - 1].node;
    }

    /// The parameter each of `functions` is a view of, where it is the same one.
    fn sameView(facts: *Facts, functions: []const Facts.Decl) Error!?usize {
        var position: ?usize = null;
        for (functions) |function| {
            const here = try facts.viewOf(function) orelse return null;
            if (position) |other| if (other != here) return null;
            position = here;
        }
        return position;
    }

    /// The place whose memory `pointer` points at, where it names one: through a view, the
    /// operand of `&x`, or an array a slice is of; null where it points at what no place here
    /// names (a pointer's own pointee, a call's result).
    pub fn pointed(facts: *Facts, file: Project.FileId, pointer: Ast.Node.Index) Error!?Ast.Node.Index {
        const tree = &facts.project.at(file).file.tree;
        const at = try viewed(facts, file, pointer);
        return switch (tree.nodeTag(at)) {
            .address_of => tree.nodeData(at).node,
            .slice_open, .slice, .slice_sentinel => {
                const base = tree.fullSlice(at).?.ast.sliced; // unreachable: the tag is a slice's
                return if (pointing(try facts.resolve(file, base))) null else base;
            },
            else => null,
        };
    }

    const Walk = struct {
        facts: *Facts,
        file: Project.FileId,
        index: *File,
        /// The declaration each declaring node makes, a variable's or a field's.
        declarations: std.AutoHashMapUnmanaged(Ast.Node.Index, Model.Declaration.Id) = .empty,
        /// Null for every site; else only those a field query needs.
        filter: ?Filter = null,
        /// The stores through a pointer a `var` of the file holds, judged once the file's
        /// stores are all known (`settle`): what the `var` holds is read from them.
        pending: std.ArrayList(Site) = .empty,

        /// Whether the walk keeps whole values' stores and outside code's writes.
        fn holders(w: *const Walk) bool {
            return if (w.filter) |f| f.holders else true;
        }

        /// Whether the walk keeps the sites of a member spelled `name`.
        fn names(w: *const Walk, name: []const u8) bool {
            return if (w.filter) |f| std.mem.eql(u8, f.name, name) else true;
        }

        /// Whether a path may name a member the walk keeps: a member, or `@field`'s name, so
        /// spelled, or a name `@field` computes, at any step.
        fn mentions(w: *const Walk, target: Ast.Node.Index) Error!bool {
            if (w.filter == null) return true;
            const tree = w.syntax();
            var node = target;
            // Whether the place is reached through what `node` gives (a member, an element, `.*`
            // of it): only then may `node` be a pointer whose memory the place is in. A place
            // that is `node` itself (`x = v`, `&x`) names no memory it points at.
            var through = false;
            while (true) switch (tree.nodeTag(node)) {
                .grouped_expression => node = tree.nodeData(node).node_and_token[0],
                .field_access => {
                    const holder, const token = tree.nodeData(node).node_and_token;
                    if (w.names(try Model.identifier(w.facts.gpa, tree.tokenSlice(token)))) return true;
                    node = holder;
                    through = true;
                },
                .array_access => {
                    node = tree.nodeData(node).node_and_node[0];
                    through = true;
                },
                .unwrap_optional => node = tree.nodeData(node).node_and_token[0],
                .deref => {
                    node = tree.nodeData(node).node;
                    through = true;
                },
                .address_of => {
                    node = tree.nodeData(node).node;
                    through = false;
                },
                else => {
                    // A view of other memory, a cast or a constant names what it points at.
                    const pointer = if (through) try viewed(w.facts, w.file, node) else node;
                    if (pointer != node) {
                        node = pointer;
                        continue;
                    }
                    if (!isField(tree, node)) return false;
                    var buffer: [2]Ast.Node.Index = undefined;
                    const args = Facts.builtinArgs(tree, node, &buffer);
                    if (args.len != 2) return true;
                    const name = try w.spelled(args[1]) orelse return true;
                    if (w.names(name)) return true;
                    node = args[0];
                },
            };
        }

        /// Whether the walk keeps a store to `target`: one that may name its member, or with
        /// `holders` any.
        fn wants(w: *const Walk, target: Ast.Node.Index) Error!bool {
            return w.holders() or try w.mentions(target);
        }

        fn syntax(w: *const Walk) *const Ast {
            return &w.facts.project.at(w.file).file.tree;
        }

        fn lexicon(w: *const Walk) *const Model {
            return &w.facts.project.at(w.file).model;
        }

        fn put(w: *Walk, place: Place, site: Site) Error!void {
            const entry = try w.index.places.getOrPut(w.facts.gpa, place);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(w.facts.gpa, site);
        }

        fn shape(w: *Walk, container: Facts.Container, site: Site) Error!void {
            const entry = try w.index.shapes.getOrPut(w.facts.gpa, .{ .file = container.file, .scope = container.scope });
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(w.facts.gpa, site);
            if (!site.through or w.filter != null) return;
            switch (site.kind) {
                .set, .update, .covered, .open => {},
                .init, .address, .read => return,
            }
            const by_node = try w.index.through.getOrPut(w.facts.gpa, site.node);
            if (!by_node.found_existing) by_node.value_ptr.* = .empty;
            try by_node.value_ptr.append(w.facts.gpa, .{ .file = container.file, .scope = container.scope });
        }

        fn named(w: *Walk, name: []const u8, site: Site) Error!void {
            const entry = try w.index.named.getOrPut(w.facts.gpa, name);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(w.facts.gpa, site);
        }

        fn unresolved(w: *Walk, site: Site) Error!void {
            try w.index.unresolved.append(w.facts.gpa, site);
        }

        fn make(w: *const Walk, node: Ast.Node.Index, target: ?Ast.Node.Index, kind: Kind, value: ?Ast.Node.Index) Site {
            return .{ .file = w.file, .node = node, .target = target, .kind = kind, .value = value, .deferred = deferred(w.syntax(), w.lexicon(), node) };
        }

        fn writes(w: *Walk) Error!void {
            const facts = w.facts;
            if (facts.project.at(w.file).file.status != .parsed) return w.unresolved(.{ .file = w.file, .node = .root, .kind = .covered });
            const tree = w.syntax();
            const own = try facts.program(w.file);
            for (w.lexicon().declarations, 0..) |record, d| switch (record.kind) {
                .variable, .field => try w.declarations.put(facts.gpa, record.node, @fromBackingInt(@intCast(d))),
                else => {},
            };
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                switch (tag) {
                    .assign => {
                        const target, const value = tree.nodeData(node).node_and_node;
                        if (try w.wants(target)) try w.store(w.make(node, target, .set, value));
                    },
                    .assign_mul, .assign_div, .assign_mod, .assign_add, .assign_sub, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_xor, .assign_bit_or, .assign_mul_wrap, .assign_add_wrap, .assign_sub_wrap, .assign_mul_sat, .assign_add_sat, .assign_sub_sat => {
                        const target, const value = tree.nodeData(node).node_and_node;
                        var site = w.make(node, target, .update, value);
                        site.operator = .{ .op = compound(tag) };
                        if (try w.wants(target)) try w.store(site);
                    },
                    .assign_destructure => {
                        const whole = tree.assignDestructure(node);
                        var buffer: [2]Ast.Node.Index = undefined;
                        const elements: ?[]const Ast.Node.Index = if (tree.fullArrayInit(&buffer, whole.ast.value_expr)) |literal| literal.ast.elements else null;
                        for (whole.ast.variables, 0..) |target, k| {
                            const value: ?Ast.Node.Index = if (elements) |each| (if (k < each.len) each[k] else null) else null;
                            if (tree.fullVarDecl(target) != null) {
                                if (w.filter != null) continue;
                                const d = w.declared(target) orelse continue;
                                try w.put(.{ .declaration = d }, w.make(node, target, .init, value));
                            } else if (try w.wants(target)) try w.store(w.make(node, target, .set, value));
                        }
                    },
                    .address_of => if (try w.mentions(tree.nodeData(node).node)) {
                        _ = try w.path(w.make(node, tree.nodeData(node).node, .address, null));
                    },
                    .slice_open, .slice, .slice_sentinel => {
                        const base = tree.fullSlice(node).?.ast.sliced; // unreachable: the tag is a slice's
                        if (try w.mentions(base) and try w.byValue(base)) _ = try w.path(w.make(node, base, .address, null));
                    },
                    .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => try w.builtin(node, own),
                    .call_one, .call_one_comma, .call, .call_comma => try w.call(node, own),
                    .asm_simple, .@"asm" => {
                        const covered = w.make(node, null, .covered, null);
                        try w.unresolved(covered);
                        // An output by name (`[out] "=r" (x)`) writes the variable it names.
                        const full = tree.fullAsm(node) orelse continue;
                        for (full.outputs) |output| {
                            const result, const rparen = tree.nodeData(output).opt_node_and_token;
                            // `(-> T)` is the result, no variable.
                            if (result.unwrap() != null) continue;
                            const name = rparen - 1;
                            if (tree.tokenTag(name) != .identifier or w.filter != null) continue;
                            const model = w.lexicon();
                            const d = model.lookup(model.scopeOf(name), tree.tokenSlice(name), name) orelse continue;
                            try w.put(.{ .declaration = .{ .file = w.file, .index = d } }, covered);
                        }
                    },
                    .for_simple, .@"for" => {
                        const loop = tree.fullFor(node).?; // unreachable: the tag is a loop's
                        var token = loop.payload_token;
                        for (loop.ast.inputs) |input| {
                            const pointer = tree.tokenTag(token) == .asterisk;
                            if (pointer) token += 1;
                            if (pointer and try w.mentions(input) and try w.byValue(input)) _ = try w.path(w.make(node, input, .address, null));
                            token += 1;
                            if (tree.tokenTag(token) == .comma) token += 1;
                        }
                    },
                    .if_simple, .@"if", .while_simple, .while_cont, .@"while" => {
                        const capture, const condition = if (tree.fullIf(node)) |branch| .{ branch.payload_token, branch.ast.cond_expr } else blk: {
                            const loop = tree.fullWhile(node).?; // unreachable: the tag is a loop's
                            break :blk .{ loop.payload_token, loop.ast.cond_expr };
                        };
                        if (capture) |token| if (tree.tokenTag(token) == .asterisk and try w.mentions(condition)) {
                            _ = try w.path(w.make(node, condition, .address, null));
                        };
                    },
                    .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => {
                        const case = tree.fullSwitchCase(node).?; // unreachable: the tag is a case's
                        const token = case.payload_token orelse continue;
                        if (tree.tokenTag(token) != .asterisk) continue;
                        const whole = w.lexicon().parentOf(node) orelse continue;
                        const subject = (tree.fullSwitch(whole) orelse continue).ast.condition;
                        if (try w.mentions(subject)) _ = try w.path(w.make(node, subject, .address, null));
                    },
                    .container_field_init, .container_field_align, .container_field => {
                        const field = w.lexicon().containerField(tree, node).?; // unreachable: the tag is a field's
                        const default = field.ast.value_expr.unwrap() orelse continue;
                        const d = w.declared(node) orelse continue;
                        if (!w.names(w.lexicon().declarations[@backingInt(d.index)].name)) continue;
                        try w.put(.{ .field = d }, w.make(node, null, .init, default));
                    },
                    else => {
                        if (tree.fullVarDecl(node)) |variable| try w.variableDecl(node, variable);
                        var buffer: [2]Ast.Node.Index = undefined;
                        if (tree.fullStructInit(&buffer, node)) |made| try w.literalFields(node, made);
                    },
                }
            }
        }

        /// The declaration a declaring node makes: a variable's, a field's.
        fn declared(w: *const Walk, node: Ast.Node.Index) ?Facts.Decl {
            return .{ .file = w.file, .index = w.declarations.get(node) orelse return null };
        }

        /// A variable's first value, and an `extern` or `export` one's memory, which code the
        /// program does not hold writes.
        fn variableDecl(w: *Walk, node: Ast.Node.Index, decl: Ast.full.VarDecl) Error!void {
            const tree = w.syntax();
            // A destructure's variables are its sites.
            if (w.lexicon().parentOf(node)) |parent| if (tree.nodeTag(parent) == .assign_destructure) return;
            const d = w.declared(node) orelse return;
            if (w.filter == null) if (decl.ast.init_node.unwrap()) |value| try w.put(.{ .declaration = d }, w.make(node, null, .init, value));
            if (decl.extern_export_token == null) return;
            const covered = w.make(node, null, .covered, null);
            try w.put(.{ .declaration = d }, covered);
            try w.shapes(covered, try w.facts.declaration(d), true);
        }

        /// A struct literal's fields, each the first value of the field in the value it makes.
        fn literalFields(w: *Walk, node: Ast.Node.Index, literal_init: Ast.full.StructInit) Error!void {
            const tree = w.syntax();
            var made: ?Facts.Value = null;
            for (literal_init.ast.fields) |value| {
                const name = try Model.identifier(w.facts.gpa, tree.tokenSlice(Model.initName(tree, value) orelse continue));
                if (!w.names(name)) continue;
                if (made == null) made = try w.facts.literalType(w.file, node);
                try w.member(w.make(node, null, .init, value), made.?, name);
            }
        }

        /// A store at `site` into its target: the place it names, every place it is part of up to
        /// the first pointer the path goes through, and the containers the stored value holds: the
        /// target's type, or where it does not resolve, the value's.
        fn store(w: *Walk, at: Site) Error!void {
            const tree = w.syntax();
            const target = at.target.?;
            if (tree.nodeTag(target) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) return;
            var whole = at;
            whole.through = try w.path(at);
            try w.index.stores.append(w.facts.gpa, whole);
            if (!w.holders()) return;
            const kind = try w.targetType(target) orelse return;
            if (kind == .unknown) if (at.value) |value| return w.shapes(whole, try w.facts.resolve(w.file, value), false);
            try w.shapes(whole, kind, false);
        }

        /// The type of what a store's target names: a field's that `@field` spells by its
        /// declaration, as `resolve` reads other targets; null for `@field` with a computed name,
        /// whose holder's type `path` takes whole.
        fn targetType(w: *Walk, target: Ast.Node.Index) Error!?Facts.Value {
            const tree = w.syntax();
            if (!isField(tree, target)) return try w.facts.resolve(w.file, target);
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, target, &buffer);
            if (args.len != 2) return .{ .unknown = .unsupported };
            const name = try w.spelled(args[1]) orelse return null;
            const container = switch (held(try w.facts.resolve(w.file, args[0]))) {
                .instance, .container => |c| c,
                else => return .{ .unknown = .unsupported },
            };
            const d = w.facts.member(container, name) orelse return .{ .unknown = .unsupported };
            return try w.facts.declaration(d);
        }

        /// Whether `pointer` is a `var` of this file whose value its stores give, while those
        /// stores are still being found: what it holds is read once they are (`settle`).
        fn heldLater(w: *Walk, pointer: Ast.Node.Index) Error!bool {
            const tree = w.syntax();
            const name = Facts.ungrouped(tree, pointer);
            if (tree.nodeTag(name) != .identifier or !try walking(w.facts, w.file)) return false;
            const d = (w.lexicon().reference(name) orelse return false).declaration orelse return false;
            const variable = tree.fullVarDecl(w.lexicon().declarations[@backingInt(d)].node) orelse return false;
            return tree.tokenTag(variable.ast.mut_token) == .keyword_var;
        }

        /// The stores `pending` holds, once the file's stores are known: one through a `var`
        /// that holds a pointer reading other memory as another type writes that memory.
        fn settle(w: *Walk) Error!void {
            for (w.pending.items) |view| if (try reinterprets(w.facts, w.file, view.target.?)) try w.pointee(view);
        }

        /// One step of a path, outermost first: a member, an element, a payload, a dereference,
        /// `@field`, or the root.
        /// The places `at.target` names, its outermost first, each inner one written in part: a
        /// name, a member, an element, an optional's payload, `@field`. A place past a pointer (a
        /// dereference, a member or an element of one) is reached through it, and the places below
        /// the pointer in the path are read, not written. Whether the target is reached through one.
        fn path(w: *Walk, at: Site) Error!bool {
            const tree = w.syntax();
            const steps = (try pathOf(w.facts, w.file, at.target.?)).steps;
            // Each step's place is reached through a pointer where it or a step below crosses one.
            const through = try w.facts.gpa.alloc(bool, steps.len);
            var below = false;
            var k = steps.len;
            while (k > 0) {
                k -= 1;
                below = below or steps[k].crosses;
                through[k] = below;
            }
            // Past a pointer the places below it in the path, the root's name among them, are read,
            // their memory not written: `list.items[i] = v` writes neither `items` nor `list`.
            var above = false;
            for (steps, through, 0..) |step, reached_through, k_| {
                if (above) break;
                above = step.crosses;
                // Past a pointer that reads other memory as another type (a view, a cast), the
                // store writes that memory, as a copy through it does
                // (`std.mem.asBytes(j)[0] = v` writes `j.*`): in part, with no one value of its
                // places.
                if (step.crosses) {
                    var view = at;
                    view.target = steps[k_ + 1].node;
                    view.value = null;
                    view.part = true;
                    if (try w.heldLater(view.target.?)) {
                        try w.pending.append(w.facts.gpa, view);
                    } else if (try reinterprets(w.facts, w.file, view.target.?)) try w.pointee(view);
                }
                var site = at;
                site.part = k_ > 0;
                site.through = reached_through;
                const root = k_ + 1 == steps.len;
                if (root) {
                    switch (tree.nodeTag(step.node)) {
                        .identifier => {
                            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(step.node)), "_")) break;
                            const reference = w.lexicon().reference(step.node) orelse {
                                try w.unresolved(site);
                                break;
                            };
                            const d = reference.declaration orelse {
                                try w.unresolved(site);
                                break;
                            };
                            try w.put(.{ .declaration = .{ .file = w.file, .index = d } }, site);
                        },
                        // A literal is memory of its own that no place the program declares
                        // names (`&.{}`, `&S{ .a = 1 }`): neither its address nor a store into
                        // it reaches one. A place it holds the address of is its own `&`'s site.
                        else => switch (formOf(tree.nodeTag(step.node))) {
                            .array_literal, .struct_literal => {},
                            // A call's result: a value of its own, which the call may have
                            // been handed.
                            else => try w.unresolved(site),
                        },
                    }
                    break;
                }
                switch (step.kind) {
                    .field => if (step.name) |name| {
                        try w.member(site, step.holder.?, name);
                    } else {
                        // A name computed as the program compiles: any field of the holder's type.
                        var any = site;
                        any.computed = true;
                        any.part = true;
                        try w.shapes(any, held(step.holder.?), false);
                    },
                    .index, .slice, .unwrap, .deref, .root => {},
                }
            }
            return below;
        }

        /// The one name `@field`'s name spells, as `Facts.fieldName` reads it (a string, a `const`
        /// holding one, an enum literal, `@tagName` of one); null for a name it computes, or one
        /// ranging over a struct's field names or a list of names: any field of the holder's type.
        fn spelled(w: *const Walk, node: Ast.Node.Index) Error!?[]const u8 {
            return switch (try w.facts.fieldName(w.file, node)) {
                .name => |name| name,
                .each_of, .names, .computed => null,
            };
        }

        /// The member `name` of what `holder` is, through pointers and optionals: a field, or a
        /// container's variable; by its name where the holder's type does not resolve.
        fn member(w: *Walk, site: Site, holder: Facts.Value, name: []const u8) Error!void {
            switch (holder) {
                // A literal returned as an error union's or optional's payload makes a value of the payload.
                .pointer => |inner| try w.member(site, inner.child.*, name),
                .optional, .error_union => |inner| try w.member(site, inner.*, name),
                .instance, .container => |container| {
                    const d = w.facts.member(container, name) orelse return w.named(name, site);
                    switch (w.facts.project.at(d.file).model.declarations[@backingInt(d.index)].kind) {
                        .field => try w.put(.{ .field = d }, site),
                        .variable => try w.put(.{ .declaration = d }, site),
                        else => {},
                    }
                },
                .alternatives => |each| for (each) |one| try w.member(site, one, name),
                .unknown, .reified, .literal, .scalar => try w.named(name, site),
                // A slice's `len` or `ptr`, an array's `len`: no container's field.
                else => {},
            }
        }

        /// The containers a value of `value`'s type holds by value, each stored or read whole at
        /// `site`, through the fields of each in turn; with `behind`, also those its pointers reach.
        /// Unresolved where a type on the way does not resolve.
        fn shapes(w: *Walk, site: Site, value: Facts.Value, behind: bool) Error!void {
            var seen: std.AutoHashMapUnmanaged(Seen, void) = .empty;
            if (!try w.collect(site, value, behind, false, &seen, 0)) try w.unresolved(site);
        }

        fn collect(w: *Walk, site: Site, value: Facts.Value, behind: bool, past: bool, seen: *std.AutoHashMapUnmanaged(Seen, void), depth: u8) Error!bool {
            if (depth >= 16) return false;
            switch (value) {
                .instance => |container| {
                    const own = !behind or past;
                    if ((try seen.getOrPut(w.facts.gpa, .{ .shape = .{ .file = container.file, .scope = container.scope }, .own = own })).found_existing) return true;
                    if (own) try w.shape(container, site);
                    // Each field's type, read with the arguments of the call that made a generic
                    // container: by value the containers it holds are stored whole with it.
                    const model = &w.facts.project.at(container.file).model;
                    for (model.declarations, 0..) |record, d| {
                        if (record.kind != .field or record.scope != container.scope) continue;
                        const field = try w.facts.memberOf(container, .{ .file = container.file, .index = @fromBackingInt(@intCast(d)) });
                        if (!try w.collect(site, field, behind, past, seen, depth + 1)) return false;
                    }
                    return true;
                },
                .array, .optional, .error_union => |inner| return w.collect(site, inner.*, behind, past, seen, depth + 1),
                .pointer => |inner| return if (behind) w.collect(site, inner.child.*, behind, true, seen, depth + 1) else true,
                .alternatives => |each| {
                    for (each) |one| if (!try w.collect(site, one, behind, past, seen, depth + 1)) return false;
                    return true;
                },
                // A literal with no type of its own holds what its parts do: handed out, a copy
                // of it reaches what their pointers reach (`.{x}` given to std's print).
                .literal => |literal| {
                    for (try w.facts.literalParts(literal)) |part| if (!try w.collect(site, part, behind, past, seen, depth + 1)) return false;
                    return true;
                },
                .unknown, .reified => return false,
                else => return true,
            }
        }

        /// A value of the type `value` names: an instance of a container, through the pointers,
        /// optionals, arrays and error unions around it.
        fn valued(w: *Walk, value: Facts.Value) Error!Facts.Value {
            const wrap = struct {
                fn boxed(facts: *Facts, inner: Facts.Value) Error!*const Facts.Value {
                    const one = try facts.gpa.create(Facts.Value);
                    one.* = inner;
                    return one;
                }
            };
            return switch (value) {
                .container => |c| .{ .instance = c },
                .pointer => |inner| .{ .pointer = .{ .child = try wrap.boxed(w.facts, try w.valued(inner.child.*)), .size = inner.size } },
                .optional => |inner| .{ .optional = try wrap.boxed(w.facts, try w.valued(inner.*)) },
                .array => |inner| .{ .array = try wrap.boxed(w.facts, try w.valued(inner.*)) },
                .error_union => |inner| .{ .error_union = try wrap.boxed(w.facts, try w.valued(inner.*)) },
                else => value,
            };
        }

        /// Whether `node`'s memory is its own (an array, a struct), so a pointer into it or a store
        /// to part of it reaches its place: anything but a pointer, and what does not resolve.
        fn byValue(w: *Walk, node: Ast.Node.Index) Error!bool {
            return !pointing(try w.facts.resolve(w.file, node));
        }

        fn builtin(w: *Walk, node: Ast.Node.Index, own: bool) Error!void {
            const tree = w.syntax();
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            for (writer_builtins) |entry| {
                if (!std.mem.eql(u8, name, entry[0])) continue;
                const pointer = if (entry[1].pointer < args.len) args[entry[1].pointer] else return;
                const value: ?Ast.Node.Index = if (entry[1].value) |k| (if (k < args.len) args[k] else null) else null;
                if (!try w.wants(pointer)) return;
                var site = w.make(node, pointer, entry[1].kind, value);
                // `@atomicRmw(T, ptr, op, operand, order)`: the operation it names.
                if (entry[1].kind == .update) site.operator = if (args.len > 2) switch (try w.facts.fieldName(w.file, args[2])) {
                    .name => |op_name| if (std.meta.stringToEnum(std.builtin.AtomicRmwOp, op_name)) |op| .{ .op = atomic(op) } else .{ .unknown = .unresolved },
                    .each_of, .names, .computed => .{ .unknown = .unsupported },
                } else .{ .unknown = .invalid_front_end };
                return w.pointee(site);
            }
            if (std.mem.eql(u8, name, "@ptrCast") or std.mem.eql(u8, name, "@bitCast")) {
                // A value of the result's type made of other memory's bits; for a pointer, the memory
                // it points at, and the operand's, written through the other type. A pointer cast
                // keeps its operand's `const`, so the operand's memory is written through it only
                // where neither it (a parameter's or a `const` declaration's address) nor the place
                // the result goes (`[]const u8`) is const.
                const covered = w.make(node, null, .covered, null);
                const made = try w.valued(try w.facts.castTypeIn(null, w.file, node));
                try w.shapes(covered, if (std.mem.eql(u8, name, "@ptrCast")) held(made) else made, false);
                if (std.mem.eql(u8, name, "@ptrCast") and args.len == 1 and !w.immutableAddress(args[0]) and !try w.facts.constPointerPlace(w.file, node)) try w.shapes(covered, held(try w.facts.resolve(w.file, uncast(tree, args[0]))), false);
                return;
            }
            if (std.mem.eql(u8, name, "@call") and args.len == 3 and own and w.holders()) {
                const callee = try w.facts.resolve(w.file, args[1]);
                if (try w.holdsBody(callee)) return;
                var tuple_buffer: [2]Ast.Node.Index = undefined;
                const tuple = tree.fullArrayInit(&tuple_buffer, args[2]) orelse return w.unresolved(w.make(node, null, .covered, null));
                for (tuple.ast.elements) |arg| try w.handed(node, arg);
            }
        }

        /// Whether `node` is the address of memory nothing writes: a parameter's or a `const`
        /// declaration's (`&value`), grouped or sliced, with no `@constCast` dropping its `const`.
        fn immutableAddress(w: *Walk, node: Ast.Node.Index) bool {
            const tree = w.syntax();
            var at = node;
            while (true) switch (tree.nodeTag(at)) {
                .grouped_expression => at = tree.nodeData(at).node_and_token[0],
                .slice, .slice_open, .slice_sentinel => at = tree.fullSlice(at).?.ast.sliced,
                .address_of => break,
                else => return false,
            };
            const target = tree.nodeData(at).node;
            if (tree.nodeTag(target) != .identifier) return false;
            const model = &w.facts.project.at(w.file).model;
            const decl = (model.reference(target) orelse return false).declaration orelse return false;
            const record = model.declarations[@backingInt(decl)];
            return switch (record.kind) {
                .parameter => true,
                .variable => if (tree.fullVarDecl(record.node)) |variable| tree.tokenTag(variable.ast.mut_token) == .keyword_const else false,
                else => false,
            };
        }

        /// An access at `at` of the memory its target points at, as `target.* = value` stores and
        /// `target.*` reads: the pointee's containers, and where the pointer is an address taken
        /// or a slice of an array, the place it is of, in part.
        fn pointee(w: *Walk, at: Site) Error!void {
            const tree = w.syntax();
            const pointer = try viewed(w.facts, w.file, at.target.?);
            var part = at;
            part.part = true;
            // The memory is reached through a pointer unless the pointer is the address of a
            // place reached by its own name (`&x`, `x[0..n]` of an array `x`).
            var through = at;
            through.through = true;
            switch (tree.nodeTag(pointer)) {
                .address_of => {
                    part.target = tree.nodeData(pointer).node;
                    through.through = try w.path(part);
                },
                .slice_open, .slice, .slice_sentinel => {
                    const base = tree.fullSlice(pointer).?.ast.sliced; // unreachable: the tag is a slice's
                    if (try w.byValue(base)) {
                        part.target = base;
                        through.through = try w.path(part);
                    }
                },
                else => {},
            }
            if (w.holders()) switch (try w.facts.resolve(w.file, pointer)) {
                .pointer => |inner| try w.shapes(through, inner.child.*, false),
                else => try w.unresolved(through),
            };
        }

        /// A call: a method's receiver whose address the call takes, and in the program's files,
        /// each pointer handed to a function whose body the program does not hold.
        fn call(w: *Walk, node: Ast.Node.Index, own: bool) Error!void {
            const tree = w.syntax();
            var buffer: [1]Ast.Node.Index = undefined;
            const full = tree.fullCall(&buffer, node).?; // unreachable: the tag is a call's
            const holder: ?Ast.Node.Index = if (tree.nodeTag(full.ast.fn_expr) == .field_access) tree.nodeData(full.ast.fn_expr).node_and_token[0] else null;
            const receiving = if (holder) |h| try w.mentions(h) else false;
            const handing = own and w.holders();
            if (!receiving and !handing) return;
            const callee = try w.facts.resolve(w.file, full.ast.fn_expr);
            if (holder) |h| {
                const receiver = try w.facts.resolve(w.file, h);
                if (receiving) switch (receiver) {
                    // A method of a value takes its address where its first parameter is a pointer.
                    .instance, .unknown, .reified, .literal => if (try w.takesPointer(callee)) {
                        _ = try w.path(w.make(node, h, .address, null));
                    },
                    else => {},
                };
                if (handing and receiver != .container and !try w.holdsBody(callee)) try w.handed(node, h);
            }
            if (!handing) return;
            if (try w.holdsBody(callee)) return w.viewsHanded(node);
            for (full.ast.params) |arg| try w.handed(node, arg);
        }

        /// A call of a function the program holds, handed a view that reads other memory as
        /// another type (`put(std.mem.asBytes(j))`): where a callee may write through the
        /// parameter it takes it as (`writtenThrough`), the memory the view reaches is written
        /// as bytes, as code the program does not hold writes it (`handed`).
        fn viewsHanded(w: *Walk, node: Ast.Node.Index) Error!void {
            const made = (try calls.at(w.facts, w.file, node)) orelse return;
            const args = switch (made.args) {
                .known => |each| each,
                .unknown => return,
            };
            const functions: []const Facts.Decl = switch (made.callee) {
                .function => |*one| one[0..1],
                .choice => |each| each,
                .any => return,
            };
            for (args, 0..) |arg, position| {
                if (!try pointerArgument(w.facts, w.file, arg) or !try reinterprets(w.facts, w.file, arg)) continue;
                for (functions) |function| {
                    const param = w.facts.parameterAt(function, position) orelse {
                        try w.handed(node, arg);
                        break;
                    };
                    if (try writtenThrough(w.facts, param)) {
                        try w.handed(node, arg);
                        break;
                    }
                }
            }
        }

        /// `arg` handed at `node` to code the program does not hold: what its pointers reach is
        /// written as it may. A view hands on the memory it views (`viewed`:
        /// `std.mem.asBytes(j)` hands what `j` points at, every field of it, not bytes alone).
        /// A value hands no memory to view; one that does not resolve keeps its own reach.
        fn handed(w: *Walk, node: Ast.Node.Index, arg: Ast.Node.Index) Error!void {
            if (inert(w.syntax(), arg)) return;
            const value = try w.facts.resolve(w.file, arg);
            const memory = if (pointing(value)) try w.facts.resolve(w.file, try viewed(w.facts, w.file, arg)) else value;
            try w.shapes(w.make(node, arg, .covered, null), memory, true);
        }

        /// Whether a callee is a function whose body the program holds: not `extern`, not a
        /// pointer's, not one that does not resolve.
        fn holdsBody(w: *Walk, callee: Facts.Value) Error!bool {
            const function = switch (callee) {
                .function => |f| f,
                else => return false,
            };
            if (!try w.facts.program(function.file)) return false;
            const model = &w.facts.project.at(function.file).model;
            // A function's declaration is its prototype; one with a body is a `fn_decl`'s.
            const whole = model.parentOf(model.declarations[@backingInt(function.index)].node) orelse return false;
            return w.facts.project.at(function.file).file.tree.nodeTag(whole) == .fn_decl;
        }

        /// Whether a callee's first parameter is a pointer, or may be one: its type does not
        /// resolve, it is `anytype`, or the callee does not.
        fn takesPointer(w: *Walk, callee: Facts.Value) Error!bool {
            const function = switch (callee) {
                .function => |f| f,
                else => return true,
            };
            const record = w.facts.project.at(function.file).model.declarations[@backingInt(function.index)];
            const tree = &w.facts.project.at(function.file).file.tree;
            var buffer: [1]Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, switch (tree.nodeTag(record.node)) {
                .fn_decl => tree.nodeData(record.node).node_and_node[0],
                else => record.node,
            }) orelse return true;
            var params = proto.iterate(tree);
            const first = params.next() orelse return false;
            const kind = first.type_expr orelse return true;
            return switch (try w.facts.resolve(function.file, kind)) {
                .pointer, .unknown, .reified, .alternatives => true,
                else => false,
            };
        }

        fn reads(w: *Walk) Error!void {
            const facts = w.facts;
            if (facts.project.at(w.file).file.status != .parsed) return w.unresolved(.{ .file = w.file, .node = .root, .kind = .read });
            const tree = w.syntax();
            const model = w.lexicon();
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                switch (tag) {
                    .identifier => {
                        const reference = model.reference(node) orelse continue;
                        const d = reference.declaration orelse continue;
                        if (try w.written(node)) continue;
                        try w.put(.{ .declaration = .{ .file = w.file, .index = d } }, .{ .file = w.file, .node = node, .target = node, .kind = .read, .part = w.inPath(node), .deferred = deferred(tree, model, node) });
                        if (!w.inPath(node)) try w.readWhole(node);
                    },
                    .field_access => {
                        if (try w.written(node)) continue;
                        const holder, const token = tree.nodeData(node).node_and_token;
                        const value = try facts.resolve(w.file, holder);
                        // A call's callee is a method or a function pointer's field, read as named.
                        try w.member(.{ .file = w.file, .node = node, .target = node, .kind = .read, .part = w.inPath(node), .deferred = deferred(tree, model, node) }, value, try Model.identifier(facts.gpa, tree.tokenSlice(token)));
                        if (!w.inPath(node)) try w.readWhole(node);
                    },
                    // An address taken reads the place as anything the pointer goes to may, as it
                    // writes it (`&x.f`, `std.mem.asBytes(&x)`).
                    .address_of => _ = try w.path(w.make(node, tree.nodeData(node).node, .address, null)),
                    .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                        try w.readBuiltin(node);
                        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field")) continue;
                        if (try w.written(node)) continue;
                        var buffer: [2]Ast.Node.Index = undefined;
                        const args = Facts.builtinArgs(tree, node, &buffer);
                        if (args.len != 2) continue;
                        const value = try facts.resolve(w.file, args[0]);
                        const read: Site = .{ .file = w.file, .node = node, .target = node, .kind = .read, .part = w.inPath(node), .deferred = deferred(tree, model, node) };
                        if (try w.spelled(args[1])) |name| try w.member(read, value, name) else {
                            var any = read;
                            any.computed = true;
                            try w.shapes(any, value, false);
                        }
                        if (!w.inPath(node)) try w.readWhole(node);
                    },
                    .deref, .array_access, .unwrap_optional => if (!w.inPath(node) and !try w.written(node)) try w.readWhole(node),
                    else => {},
                }
            }
        }

        /// What a memory builtin reads through the pointer it is given, as `builtin`'s writers
        /// write theirs: a copy's source, the memory an atomic loads, replaces or compares.
        fn readBuiltin(w: *Walk, node: Ast.Node.Index) Error!void {
            const tree = w.syntax();
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            for (reader_builtins) |entry| {
                if (!std.mem.eql(u8, name, entry[0])) continue;
                if (entry[1] >= args.len) return;
                return w.pointee(w.make(node, args[entry[1]], .read, null));
            }
        }

        /// Whether `node` is the holder in a longer path: a member's, an element's, a payload's,
        /// `@field`'s.
        fn inPath(w: *const Walk, node: Ast.Node.Index) bool {
            const tree = w.syntax();
            const parent = w.lexicon().parentOf(node) orelse return false;
            return switch (tree.nodeTag(parent)) {
                .field_access, .unwrap_optional => tree.nodeData(parent).node_and_token[0] == node,
                .array_access => tree.nodeData(parent).node_and_node[0] == node,
                .grouped_expression => w.inPath(parent),
                else => isField(tree, parent) and holderOf(tree, parent) == node,
            };
        }

        /// Whether `node` names memory a store writes without reading it: the target of `=` or of
        /// a destructure, the operand of `&` (its address is its site), or a holder in such a path
        /// up to the first pointer. A store's other operands, an `op=`'s target and a pointer
        /// stored through are read.
        fn written(w: *Walk, node: Ast.Node.Index) Error!bool {
            const tree = w.syntax();
            var at = node;
            while (true) {
                const parent = w.lexicon().parentOf(at) orelse return false;
                switch (tree.nodeTag(parent)) {
                    .assign => return tree.nodeData(parent).node_and_node[0] == at,
                    .assign_destructure => return true,
                    .address_of => return true,
                    .grouped_expression => at = parent,
                    .field_access, .unwrap_optional => {
                        if (tree.nodeData(parent).node_and_token[0] != at) return false;
                        if (pointing(try w.facts.resolve(w.file, at))) return false;
                        at = parent;
                    },
                    .array_access => {
                        if (tree.nodeData(parent).node_and_node[0] != at) return false;
                        if (!try w.byValue(at)) return false;
                        at = parent;
                    },
                    else => {
                        if (!isField(tree, parent) or holderOf(tree, parent) != at) return false;
                        if (pointing(try w.facts.resolve(w.file, at))) return false;
                        at = parent;
                    },
                }
            }
        }

        /// A value read whole at `node` (copied, passed, compared): each field its type holds by
        /// value is read.
        fn readWhole(w: *Walk, node: Ast.Node.Index) Error!void {
            const site: Site = .{ .file = w.file, .node = node, .target = node, .kind = .read, .deferred = deferred(w.syntax(), w.lexicon(), node) };
            try w.shapes(site, try w.targetType(node) orelse return, false);
        }
    };

    /// What a holder holds its members in: the value a pointer or an optional of it points at.
    pub fn held(value: Facts.Value) Facts.Value {
        return switch (value) {
            .pointer => |inner| held(inner.child.*),
            .optional => |inner| held(inner.*),
            else => value,
        };
    }

    /// Whether `node` is `@field(holder, name)`.
    fn isField(tree: *const Ast, node: Ast.Node.Index) bool {
        return switch (tree.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field"),
            else => false,
        };
    }

    /// A pointer past the casts that keep what it points at: `@alignCast`, `@constCast`,
    /// `@volatileCast`, parentheses.
    pub fn uncast(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
        var at = node;
        while (true) switch (tree.nodeTag(at)) {
            .grouped_expression => at = tree.nodeData(at).node_and_token[0],
            .builtin_call_two, .builtin_call_two_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(at));
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, at, &buffer);
                if (args.len != 1) return at;
                for (Facts.pointee_keeping) |keeping| {
                    if (std.mem.eql(u8, name, keeping)) break;
                } else return at;
                at = args[0];
            },
            else => return at,
        };
    }

    /// The holder `@field(holder, name)` names a member of.
    fn holderOf(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        return if (args.len == 2) args[0] else null;
    }

    /// Whether a value is a pointer, or may be one: a member of it reaches through it.
    fn pointing(value: Facts.Value) bool {
        return switch (value) {
            .pointer => true,
            .alternatives => |each| for (each) |one| {
                if (one == .pointer) break true;
            } else false,
            else => false,
        };
    }

    /// Whether `name` on a pointer `value` is a slice's own `len` or `ptr` (`Facts.memoryField`):
    /// the slice's memory, not what it points at. A container's own member, or one of a value
    /// that does not resolve, is reached through the pointer.
    fn header(facts: *Facts, name: []const u8, value: Facts.Value) Error!bool {
        if (!std.mem.eql(u8, name, "len") and !std.mem.eql(u8, name, "ptr")) return false;
        return try facts.lengthOfValue(value, name) != .field;
    }

    /// Whether `node` runs in a `defer` or an `errdefer` of its function.
    fn deferred(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
        var at = node;
        while (model.parentOf(at)) |parent| : (at = parent) switch (tree.nodeTag(parent)) {
            .@"defer", .@"errdefer" => return true,
            .fn_decl => return false,
            else => {},
        };
        return false;
    }
};

/// Every call by meaning: `f(a)`, a method's `x.f(a)`, `@call(modifier, f, .{a})`, a callee
/// named through `@field`, a decl literal (`.init(n)`), a constant bound to a function or its
/// address, a function pointer.
/// Each with the function it calls, a choice of them, or `any`: a rule asks here what a call
/// calls, and reads `any` as undecided, never as a call of none.
pub const calls = struct {
    pub const Callee = union(enum) {
        function: Facts.Decl,
        /// One of these, each known: a function pointer's every store, a mutable local's.
        choice: []const Facts.Decl,
        /// It may call any function: why its callee is not known.
        any: Facts.Unknown,
    };

    /// Whether a call binds a value as its callee's first parameter.
    pub const Receiver = union(enum) {
        /// It binds none: `f(a)`, `T.f(a)`, `@call`, a call through a function-pointer field.
        none,
        /// `x` of `x.f(a)`, bound as the first parameter.
        bound: Ast.Node.Index,
        /// It may bind one or not: why the holder or its member is not known.
        unknown: Facts.Unknown,
    };

    /// What a call passes.
    pub const Args = union(enum) {
        /// In the callee's parameter order, a bound receiver first.
        known: []const Ast.Node.Index,
        /// Why which argument a parameter takes is not known: a receiver that may bind or not,
        /// `@call` given no tuple literal.
        unknown: Facts.Unknown,
    };

    pub const Call = struct {
        file: Project.FileId,
        /// The call: `f(a)`'s node, or `@call`'s.
        node: Ast.Node.Index,
        /// What it calls, as written: `f(a)`'s `f`, `@call`'s second argument.
        callee_expr: Ast.Node.Index,
        /// An unknown receiver leaves `args` unknown, for the same reason.
        receiver: Receiver = .none,
        args: Args,
        /// `@call`'s modifier.
        modifier: ?Ast.Node.Index = null,
        callee: Callee,
        /// A call another call makes later (`deferredOf`): it may run after the statement that
        /// makes it, until the future that call gives is awaited, cancelled or joined.
        deferred: bool = false,
    };

    pub const Error = Facts.ResolveError;

    const State = struct { files: std.AutoHashMapUnmanaged(Project.FileId, []const Call) = .empty };

    /// The call `node` makes, or null where it makes none.
    pub fn at(facts: *Facts, file: Project.FileId, node: Ast.Node.Index) Error!?Call {
        return under(facts, null, file, node);
    }

    /// Whether `node` is written as a call `under` reads: `f(a)` or `@call`. By its form alone.
    pub fn written(tree: *const Ast, node: Ast.Node.Index) bool {
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, node) != null) return true;
        return switch (tree.nodeTag(node)) {
            .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@call"),
            else => false,
        };
    }

    /// The call `node` makes in one instantiation of the generic it is in: read under `env`, a
    /// reading `Facts.bind` made for each call down the chain that reaches it, so a call on
    /// what a generic's parameter binds (`ctx.hash(key)` in std's `HashMap`, its context
    /// `anytype` or a type parameter of its container) calls what that instantiation is given.
    /// Under null, as every instantiation reads it (`at`).
    pub fn under(facts: *Facts, env: ?*const Facts.Env, file: Project.FileId, node: Ast.Node.Index) Error!?Call {
        const tree = &facts.project.at(file).file.tree;
        var call_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&call_buffer, node)) |call| {
            const fn_expr = call.ast.fn_expr;
            const receiver = try bound(facts, env, file, fn_expr);
            const args: Args = switch (receiver) {
                // `f(a)`'s argument may be in `call_buffer`: copied out of this frame.
                .none => .{ .known = try facts.gpa.dupe(Ast.Node.Index, call.ast.params) },
                .bound => |holder| .{ .known = try std.mem.concat(facts.gpa, Ast.Node.Index, &.{ &.{holder}, call.ast.params }) },
                .unknown => |why| .{ .unknown = why },
            };
            return .{
                .file = file,
                .node = node,
                .callee_expr = fn_expr,
                .receiver = receiver,
                .args = args,
                .callee = try calleeOf(facts, env, file, fn_expr),
            };
        }
        switch (tree.nodeTag(node)) {
            .builtin_call, .builtin_call_comma => {},
            else => return null,
        }
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@call")) return null;
        var buffer: [2]Ast.Node.Index = undefined;
        const operands = Facts.builtinArgs(tree, node, &buffer);
        if (operands.len != 3) return null;
        // `@call` binds no receiver: a method is named through its type, the value in the tuple.
        return .{ .file = file, .node = node, .callee_expr = operands[1], .args = try tupleArgs(facts, tree, operands[2]), .modifier = operands[0], .callee = try calleeOf(facts, env, file, operands[1]) };
    }

    /// What a tuple handed as a call's arguments passes (`@call`'s, a function-running call's):
    /// a literal's elements, in order; unknown for any other tuple.
    fn tupleArgs(facts: *Facts, tree: *const Ast, node: Ast.Node.Index) Error!Args {
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullArrayInit(&buffer, node)) |literal|
            return if (literal.ast.type_expr == .none) .{ .known = try facts.gpa.dupe(Ast.Node.Index, literal.ast.elements) } else .{ .unknown = .unsupported };
        // `.{}` parses as a struct literal: an empty tuple.
        if (tree.fullStructInit(&buffer, node)) |empty|
            return if (empty.ast.type_expr == .none and empty.ast.fields.len == 0) .{ .known = &.{} } else .{ .unknown = .unsupported };
        return .{ .unknown = .unsupported };
    }

    /// Which of a function's parameters (in its parameter order) it runs, and with which
    /// tuple: a function-running function (`Io.concurrent(io, function, args)`).
    pub const Runs = struct { function: usize, args: usize };

    /// The call of its function argument that `call` makes later, if the function it calls
    /// runs one (`runsWith`): `io.concurrent(f, .{ io, &s })` calls `f` with the tuple's
    /// elements, read as `@call` reads them, `deferred`. Its result is the future `call` gives,
    /// never `f`'s. Null where `call` runs no function it is given, or what it calls is not one
    /// function.
    pub fn deferredOf(facts: *Facts, call: Call) Error!?Call {
        const callee = switch (call.callee) {
            .function => |function| function,
            .choice, .any => return null,
        };
        const runs = (try runsWith(facts, callee)) orelse return null;
        const args = switch (call.args) {
            .known => |each| each,
            .unknown => return null,
        };
        if (runs.function >= args.len or runs.args >= args.len) return null;
        const tree = &facts.project.at(call.file).file.tree;
        return .{
            .file = call.file,
            .node = call.node,
            .callee_expr = args[runs.function],
            .args = try tupleArgs(facts, tree, args[runs.args]),
            .callee = try calleeOf(facts, null, call.file, args[runs.function]),
            .deferred = true,
        };
    }

    const Running = struct { found: std.AutoHashMapUnmanaged(Facts.Decl, ?Runs) = .empty };

    /// Whether `function` runs a function it is given with a tuple it is given, by meaning: its
    /// tuple parameter is declared `std.meta.ArgsTuple(@TypeOf(f))` of its function parameter
    /// `f` (std's `Io.async`, `Io.concurrent`, a group's), or its body runs the two: `@call` of
    /// them, or a call of a function-running function handed them (`Thread.spawn` forwarding to
    /// its target's). Null where it runs none known.
    pub fn runsWith(facts: *Facts, function: Facts.Decl) Error!?Runs {
        return runsWithAt(facts, function, 0);
    }

    fn runsWithAt(facts: *Facts, function: Facts.Decl, depth: u8) Error!?Runs {
        const state = try facts.memo(Running);
        if (state.found.get(function)) |kept| return kept;
        // Until it is known, a function that reaches itself runs nothing it is given.
        try state.found.put(facts.gpa, function, null);
        const found = try runsFound(facts, function, depth);
        try state.found.put(facts.gpa, function, found);
        return found;
    }

    fn runsFound(facts: *Facts, function: Facts.Decl, depth: u8) Error!?Runs {
        if (depth == 8) return null;
        const model = &facts.project.at(function.file).model;
        const tree = &facts.project.at(function.file).file.tree;
        const record = model.declarations[@backingInt(function.index)];
        if (record.kind != .function) return null;
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&proto_buffer, record.node) orelse return null;
        var names: [16]Ast.TokenIndex = @splat(0);
        var types: [16]?Ast.Node.Index = @splat(null);
        var count: usize = 0;
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            if (count == names.len) return null;
            names[count] = param.name_token orelse return null;
            types[count] = param.type_expr;
            count += 1;
        }
        const params = names[0..count];
        // Declared: `args: std.meta.ArgsTuple(@TypeOf(function))`.
        const args_tuple = try facts.stdMember(&.{ "meta", "ArgsTuple" });
        if (args_tuple == .function) for (types[0..count], 0..) |declared, position| {
            const t = declared orelse continue;
            var buffer: [1]Ast.Node.Index = undefined;
            const made = tree.fullCall(&buffer, t) orelse continue;
            if (made.ast.params.len != 1) continue;
            const maker = try facts.resolve(function.file, made.ast.fn_expr);
            if (maker != .function or !std.meta.eql(maker.function, args_tuple.function)) continue;
            const of = made.ast.params[0];
            if (!Facts.isBuiltin(tree, of, "@TypeOf")) continue;
            var type_buffer: [2]Ast.Node.Index = undefined;
            const operands = Facts.builtinArgs(tree, of, &type_buffer);
            if (operands.len != 1) continue;
            const ran = parameterNamed(model, tree, params, operands[0]) orelse continue;
            return .{ .function = ran, .args = position };
        };
        // Its body runs them: `@call(_, function, args)`, or a call handing them on to a
        // function that runs them, each it may call alike.
        const whole = if (tree.nodeTag(record.node) == .fn_decl) record.node else model.parentOf(record.node) orelse return null;
        if (tree.nodeTag(whole) != .fn_decl) return null;
        const body = tree.nodeData(whole).node_and_node[1];
        const first = tree.firstToken(body);
        const last = tree.lastToken(body);
        for (try in(facts, function.file)) |call| {
            const token = tree.nodeMainToken(call.node);
            if (token < first or token > last) continue;
            if (call.modifier != null) {
                var buffer: [2]Ast.Node.Index = undefined;
                const operands = Facts.builtinArgs(tree, call.node, &buffer);
                const ran = parameterNamed(model, tree, params, operands[1]) orelse continue;
                const with = parameterNamed(model, tree, params, operands[2]) orelse continue;
                return .{ .function = ran, .args = with };
            }
            const args = switch (call.args) {
                .known => |each| each,
                .unknown => continue,
            };
            const each: []const Facts.Decl = switch (call.callee) {
                .function => |one| &.{one},
                .choice => |choice| choice,
                .any => continue,
            };
            var agreed: ?Runs = null;
            for (each) |callee| {
                const inner = (try runsWithAt(facts, callee, depth + 1)) orelse break;
                if (inner.function >= args.len or inner.args >= args.len) break;
                const ran = parameterNamed(model, tree, params, args[inner.function]) orelse break;
                const with = parameterNamed(model, tree, params, args[inner.args]) orelse break;
                const runs: Runs = .{ .function = ran, .args = with };
                if (agreed) |one| if (!std.meta.eql(one, runs)) break;
                agreed = runs;
            } else if (agreed) |runs| return runs;
        }
        return null;
    }

    /// The position among `params` of the parameter `node` names, as written (`f`, `(f)`).
    fn parameterNamed(model: *const Model, tree: *const Ast, params: []const Ast.TokenIndex, node: Ast.Node.Index) ?usize {
        const named = ungrouped(tree, node);
        const ref = model.reference(named) orelse return null;
        const index = ref.declaration orelse return null;
        const decl = model.declarations[@backingInt(index)];
        if (decl.kind != .parameter) return null;
        for (params, 0..) |name, position| if (name == decl.token) return position;
        return null;
    }

    /// Every call `file` makes, as `at` reads each. Found once.
    pub fn in(facts: *Facts, file: Project.FileId) Error![]const Call {
        const state = try facts.memo(State);
        if (state.files.get(file)) |kept| return kept;
        const wide = facts.wide;
        var found: std.ArrayList(Call) = .empty;
        const tree = &facts.project.at(file).file.tree;
        for (0..tree.nodes.len) |i| {
            if (try at(facts, file, @fromBackingInt(@intCast(i)))) |call| try found.append(facts.gpa, call);
        }
        // Read on an answer wider than the analysis gives once built, it is not kept (`wide`).
        if (!facts.wideSince(wide)) try state.files.put(facts.gpa, file, found.items);
        return found.items;
    }

    /// Whether `x.f(a)` binds `x` as `f`'s first parameter: where `f` is a function declared in
    /// `x`'s type and `x` a value of it. `T.f(a)` binds nothing; a holder that does not resolve
    /// may bind it or not.
    fn bound(facts: *Facts, env: ?*const Facts.Env, file: Project.FileId, fn_expr: Ast.Node.Index) Error!Receiver {
        const tree = &facts.project.at(file).file.tree;
        const callee = ungrouped(tree, fn_expr);
        const holder = switch (tree.nodeTag(callee)) {
            .field_access => tree.nodeData(callee).node_and_token[0],
            .builtin_call_two, .builtin_call_two_comma => blk: {
                if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(callee)), "@field")) return .none;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, callee, &buffer);
                if (args.len != 2) return .none;
                break :blk args[0];
            },
            else => return .none,
        };
        const value = try facts.resolveIn(env, file, holder);
        // A type's member, or a typeless literal's field, binds nothing.
        if (value == .container or value == .literal) return .none;
        // A choice of holders (`if (T == bool) &memo.found else &memo.needed`): bound where
        // each is a value whose member so named is a method, as one holder is.
        if (value == .alternatives) {
            if (tree.nodeTag(callee) != .field_access) return .{ .unknown = .unsupported };
            const name = try facts.memberName(tree.tokenSlice(tree.nodeData(callee).node_and_token[1]));
            for (value.alternatives) |one| {
                const container = switch (one) {
                    .instance => |c| c,
                    .pointer => |inner| switch (inner.child.*) {
                        .instance => |c| c,
                        else => return .{ .unknown = .unsupported },
                    },
                    .optional => |inner| switch (inner.*) {
                        .instance => |c| c,
                        else => return .{ .unknown = .unsupported },
                    },
                    .unknown => |why| return .{ .unknown = why },
                    else => return .{ .unknown = .unsupported },
                };
                const decl = facts.member(container, name) orelse return .{ .unknown = .unresolved };
                if (facts.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind != .function) return .{ .unknown = .unsupported };
            }
            return .{ .bound = holder };
        }
        // A field holds what it is given, and a call through it binds nothing.
        const decl = switch (try memberNamed(facts, env, file, callee, value)) {
            .decl => |d| d,
            // No member so named of a holder that resolves: what it calls is not known.
            .none => return .{ .unknown = if (value == .unknown) value.unknown else .unresolved },
            .unknown => |why| return .{ .unknown = why },
        };
        switch (facts.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind) {
            .function => {},
            .field => return .none,
            // A constant whose value is a function is a method as its declaration would be
            // (std's `pub const hash = getAutoHashFn(K, @This())`); one not known may be.
            else => switch (try facts.declaration(decl)) {
                .function => {},
                .unknown => |why| return .{ .unknown = why },
                .alternatives => return .{ .unknown = .unsupported },
                else => return .none,
            },
        }
        return switch (value) {
            .instance, .pointer, .optional => .{ .bound = holder },
            .unknown => |why| .{ .unknown = why },
            else => .{ .unknown = .unsupported },
        };
    }

    /// The declaration `x.name` or `@field(x, "name")` names; under `env`, the member so named
    /// of the container `holder`, the value of `x` there, is (`ctx.hash` of the context an
    /// instantiation is given), where it is one.
    fn memberNamed(facts: *Facts, env: ?*const Facts.Env, file: Project.FileId, node: Ast.Node.Index, holder: Facts.Value) Error!Facts.Named {
        const tree = &facts.project.at(file).file.tree;
        if (env != null and tree.nodeTag(node) == .field_access) {
            const container: ?Facts.Container = switch (holder) {
                .instance, .container => |c| c,
                .pointer => |inner| switch (inner.child.*) {
                    .instance, .container => |c| c,
                    else => null,
                },
                .optional => |inner| switch (inner.*) {
                    .instance, .container => |c| c,
                    else => null,
                },
                else => null,
            };
            if (container) |c| if (facts.member(c, try facts.memberName(tree.tokenSlice(tree.nodeData(node).node_and_token[1])))) |found| return .{ .decl = found };
        }
        return switch (tree.nodeTag(node)) {
            .field_access => facts.definition(file, node),
            else => facts.reflected(file, node),
        };
    }

    /// What calling the value of `node` calls: each function a source of it gives.
    /// What calling the value of `node` calls, as `Facts.resolve` gives the value: each function
    /// it names (a function, a pointer to one, a choice of them), none of an optional's `null`;
    /// any where it names a function's type alone or does not resolve.
    fn calleeOf(facts: *Facts, env: ?*const Facts.Env, file: Project.FileId, node: Ast.Node.Index) Error!Callee {
        var found: std.ArrayList(Facts.Decl) = .empty;
        if (try functionsIn(facts, try facts.resolveIn(env, file, node), &found)) |why| return .{ .any = why };
        return switch (found.items.len) {
            // No source gives it a function: nothing it calls is known.
            0 => .{ .any = .unresolved },
            1 => .{ .function = found.items[0] },
            else => .{ .choice = found.items },
        };
    }

    /// Adds each function `value` names to `found`; why not, where it may be any.
    fn functionsIn(facts: *Facts, value: Facts.Value, found: *std.ArrayList(Facts.Decl)) Error!?Facts.Unknown {
        switch (value) {
            .function => |decl| try add(facts, found, decl),
            .pointer => |inner| return functionsIn(facts, inner.child.*, found),
            .optional => |inner| return functionsIn(facts, inner.*, found),
            .alternatives => |each| for (each) |one| {
                // `null`, which no call reaches.
                if (one == .scalar) continue;
                if (try functionsIn(facts, one, found)) |why| return why;
            },
            .unknown => |why| return why,
            else => return .unresolved,
        }
        return null;
    }

    fn add(facts: *Facts, found: *std.ArrayList(Facts.Decl), one: Facts.Decl) Error!void {
        for (found.items) |seen| if (std.meta.eql(seen, one)) return;
        try found.append(facts.gpa, one);
    }
};

test "facts aliases cycles and absent module mappings stay unknown" {
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "const A = B; const B = A; const dep = @import(\"missing\");" }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const first = project.sources[0].file.tree.fullVarDecl(project.sources[0].model.declarations[0].node).?.ast.init_node.unwrap().?;
    try std.testing.expectEqual(Unknown.cycle, (try facts.resolve(project.sources[0].id, first)).unknown);
    const dep = project.sources[0].file.tree.fullVarDecl(project.sources[0].model.declarations[2].node).?.ast.init_node.unwrap().?;
    try std.testing.expectEqual(Unknown.missing_mapping, (try facts.resolve(project.sources[0].id, dep)).unknown);
}

test "facts read a ZON import as the value its file holds" {
    const root =
        \\const K = struct { bytes: [2]u8 };
        \\const k: K = @import("k.zon");
        \\const data = @import("k.zon");
        \\const bytes = data.bytes;
        \\const n = @import("n.zon");
        \\const gone = @import("gone.zon");
        \\const text = @import("text.zig");
    ;
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root.zig", .bytes = root },
        .{ .name = "k.zon", .bytes = ".{ .bytes = .{ 1, 2 } }", .kind = .zon },
        .{ .name = "n.zon", .bytes = "42", .kind = .zon },
        .{ .name = "text.zig", .bytes = "pub const x = 1;" },
    }, &.{
        .{ .from = 0, .spelling = "k.zon", .target = 1 },
        .{ .from = 0, .spelling = "n.zon", .target = 2 },
        .{ .from = 0, .spelling = "text.zig", .target = 3 },
    }, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const Of = struct {
        fn decl(p: *const Project, name: []const u8) Decl {
            for (p.sources[0].model.declarations, 0..) |d, i| if (d.kind == .variable and std.mem.eql(u8, d.name, name)) return .{ .file = p.sources[0].id, .index = @fromBackingInt(@intCast(i)) };
            unreachable; // the test's source declares each name it asks for
        }
    };
    const zon = project.sources[1].id;
    // Typed by its declaration, as a literal written in place is: K's instance.
    const k = try facts.declaration(Of.decl(&project, "k"));
    const k_type = try facts.declaration(Of.decl(&project, "K"));
    try std.testing.expect(k_type == .container and k == .instance and std.meta.eql(k.instance, k_type.container));
    // Untyped: the file's struct literal, and a field of it the literal it gives that field.
    const data = try facts.declaration(Of.decl(&project, "data"));
    try std.testing.expect(data == .literal and data.literal.file == zon);
    const part = try facts.declaration(Of.decl(&project, "bytes"));
    try std.testing.expect(part == .literal and part.literal.file == zon and project.sources[1].file.tree.nodeTag(part.literal.node) == .array_init_dot_two);
    // A number, as one written in place.
    try std.testing.expectEqual(Value.scalar, try facts.declaration(Of.decl(&project, "n")));
    // A ZON file the run did not load stays unmapped, never empty.
    try std.testing.expectEqual(Unknown.missing_mapping, (try facts.declaration(Of.decl(&project, "gone"))).unknown);
    // A Zig file's import is its namespace.
    try std.testing.expect(try facts.declaration(Of.decl(&project, "text")) == .container);
}

test "facts read a ZON file's literals as the same literals placed in place, or not at all" {
    // ZON's names (`true`, `null`, `inf`, `nan`) are no references of a Model: what each part
    // of the ZON literal resolves to is what it does placed in a Zig file, or unknown.
    const parts = ".t = true, .f = false, .z = null, .e = .tag, .c = 'x', .s = \"str\", .n = 7, .x = 1.5, .a = .{ 1, 2 }";
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root.zig", .bytes = "const v = .{ " ++ parts ++ " };\nconst data = @import(\"v.zon\");\n" },
        .{ .name = "v.zon", .bytes = ".{ " ++ parts ++ ", .i = inf, .m = -inf, .q = nan }", .kind = .zon },
    }, &.{.{ .from = 0, .spelling = "v.zon", .target = 1 }}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const root = project.sources[0].id;
    const in_place = try facts.declaration(facts.member(facts.rootOf(root), "v").?);
    const from_zon = try facts.declaration(facts.member(facts.rootOf(root), "data").?);
    try std.testing.expect(in_place == .literal and from_zon == .literal);
    const placed = try facts.literalParts(in_place.literal);
    const read = try facts.literalParts(from_zon.literal);
    try std.testing.expectEqual(placed.len + 3, read.len);
    // ZON's `inf`, `-inf` and `nan`, which Zig code does not spell: a number, or unknown.
    for (read[placed.len..]) |r| try std.testing.expect(r == .scalar or r == .unknown);
    for (placed, read[0..placed.len], 0..) |w, r, i| {
        if (r == .unknown or std.meta.eql(w, r) or (w == .literal and r == .literal)) continue;
        std.debug.print("part {d}: in place {t}, from ZON {t}\n", .{ i, w, r });
        return error.TestUnexpectedResult;
    }
    // A bool std's ZON reader takes is known as placed, or not known: never the other.
    const zon_tree = &project.sources[1].file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const fields = zon_tree.fullStructInit(&buffer, from_zon.literal.node).?.ast.fields;
    try std.testing.expect((try facts.knownBool(project.sources[1].id, fields[0])) orelse true);
    try std.testing.expect(!((try facts.knownBool(project.sources[1].id, fields[1])) orelse false));
    try std.testing.expect(isNull(zon_tree, fields[2]));
}

test "a function stores through a parameter, or returns, what another holds or its own address, through captures, branches and callees' results, recursion read as the least answer" {
    const source =
        \\const N = struct { next: ?*N = null, v: u8 = 0 };
        \\fn link(self: *N) void { self.next = self; }
        \\fn set(self: *N, v: u8) void { self.v = v; }
        \\fn down(self: *N, n: u8) void { if (n > 0) down(self, n - 1); self.v = n; }
        \\fn reach(self: *N, n: u8) void { if (n > 0) reach(self, n - 1) else link(self); }
        \\fn keep(self: *N, other: *N) void { self.next = other; }
        \\fn copy(self: *N, other: *N) void { self.v = other.v; }
        \\fn deep(self: *N, other: *N) void { self.next = other.next; }
        \\fn pass(self: *N, other: *N) void { keep(other, self); }
        \\fn itself(self: *N) *N { return self; }
        \\fn after(self: *N) ?*N { return self.next; }
        \\fn relink(self: *N) void { self.next = itself(self); }
        \\fn skip(self: *N) void { self.next = after(self); }
        \\fn each(self: *N, all: []N) void { for (all) |*n| self.next = n; }
        \\fn again(self: *N) void { if (self.next) |n| self.next = n; }
        \\fn either(self: *N, other: *N, b: bool) void { self.next = if (b) other else null; }
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const named = struct {
        fn of(p: *const Project, name: []const u8) Decl {
            for (p.sources[0].model.declarations, 0..) |decl, i| if (decl.kind == .function and std.mem.eql(u8, decl.name, name)) return .{ .file = p.sources[0].id, .index = @fromBackingInt(@intCast(i)) };
            unreachable;
        }
    }.of;
    try std.testing.expectEqual(@as(?bool, true), try facts.storesAddress(named(&project, "link"), 0, 0));
    try std.testing.expectEqual(@as(?bool, false), try facts.storesAddress(named(&project, "set"), 0, 0));
    try std.testing.expectEqual(@as(?bool, false), try facts.storesAddress(named(&project, "down"), 0, 0));
    try std.testing.expectEqual(@as(?bool, true), try facts.storesAddress(named(&project, "reach"), 0, 0));
    try std.testing.expectEqual(@as(?bool, true), try facts.storesAddress(named(&project, "keep"), 0, 1));
    try std.testing.expectEqual(@as(?bool, false), try facts.storesAddress(named(&project, "keep"), 0, 0));
    try std.testing.expectEqual(@as(?bool, false), try facts.storesAddress(named(&project, "copy"), 0, 1));
    try std.testing.expectEqual(@as(?bool, true), try facts.storesAddress(named(&project, "deep"), 0, 1));
    try std.testing.expectEqual(@as(?bool, true), try facts.storesAddress(named(&project, "pass"), 1, 0));
    try std.testing.expectEqual(@as(?bool, false), try facts.storesAddress(named(&project, "pass"), 0, 1));
    try std.testing.expectEqual(@as(?bool, true), try facts.returnsAddress(named(&project, "itself"), 0, false));
    try std.testing.expectEqual(@as(?bool, false), try facts.returnsAddress(named(&project, "after"), 0, false));
    try std.testing.expectEqual(@as(?bool, true), try facts.returnsAddress(named(&project, "after"), 0, true));
    try std.testing.expectEqual(@as(?bool, true), try facts.storesAddress(named(&project, "relink"), 0, 0));
    try std.testing.expectEqual(@as(?bool, false), try facts.storesAddress(named(&project, "skip"), 0, 0));
    try std.testing.expectEqual(@as(?bool, true), try facts.storesAddress(named(&project, "each"), 0, 1));
    try std.testing.expectEqual(@as(?bool, false), try facts.storesAddress(named(&project, "again"), 0, 0));
    try std.testing.expectEqual(@as(?bool, true), try facts.storesAddress(named(&project, "either"), 0, 1));
    try std.testing.expectEqual(@as(?bool, false), try facts.storesAddress(named(&project, "either"), 0, 0));
}

test "a program's builtin is Zig's own per-build file, its root a mapping the build gives" {
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "const builtin = @import(\"builtin\"); const root = @import(\"root\"); const tag = builtin.os.tag;" }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const source = &project.sources[0];
    const init = struct {
        fn of(s: *const Project.Source, i: usize) Ast.Node.Index {
            return s.file.tree.fullVarDecl(s.model.declarations[i].node).?.ast.init_node.unwrap().?;
        }
    }.of;
    try std.testing.expectEqual(Unknown.zig_own, (try facts.resolve(source.id, init(source, 0))).unknown);
    try std.testing.expectEqual(Unknown.missing_mapping, (try facts.resolve(source.id, init(source, 1))).unknown);
    // A file whose one import is the compiler's `builtin` reads every file it imports.
    var alone = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "const builtin = @import(\"builtin\"); pub const debug = builtin.mode == .Debug;" }}, &.{}, .{});
    defer alone.deinit();
    var alone_facts: Facts = .{ .project = &alone, .gpa = arena.allocator() };
    defer alone_facts.deinit();
    try std.testing.expect(try alone_facts.importsRead(alone.sources[0].id));
}

test "a call that passes what a module the build does not have gives binds nothing" {
    const source = "const k = @import(\"kernels\");\nconst S = struct { used: usize };\nfn local() S { return .{ .used = 0 }; }\nfn folded(comptime fold: anytype) usize { const f = fold(); return f.used; }\npub fn a() usize { return folded(local); }\npub fn b() usize { return folded(k.fold); }";
    for ([_]bool{ false, true }) |absent_kernels| {
        const names: []const []const u8 = if (absent_kernels) &.{"kernels"} else &.{};
        var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source, .absent = names }}, &.{}, .{});
        defer project.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
        defer facts.deinit();
        const model = &project.sources[0].model;
        const f = for (model.declarations) |d| {
            if (d.kind == .variable and std.mem.eql(u8, d.name, "f")) break d;
        } else unreachable; // unreachable: the source declares `f`
        const init = project.sources[0].file.tree.fullVarDecl(f.node).?.ast.init_node.unwrap().?;
        const value = try facts.resolve(project.sources[0].id, init);
        // Unmapped, `k.fold` is unknown and so is the binding; absent, its call is not compiled.
        try std.testing.expectEqual(absent_kernels, value == .instance);
    }
}

/// The type a struct literal takes from where it is written, as Zig gives it a result type: a
/// typed literal's own; a declaration's written type; an assignment's target; a call's
/// parameter, read with a made container's arguments for its methods; its function's result
/// for a `return`; a typed literal's field or array's element; `@as`; and through a grouping,
/// a branch or a block's `break`. `.scalar` where nothing gives it one (an untyped `const`, an
/// `anytype` argument): it is then an anonymous struct. Unknown where the place does not
/// resolve.
pub fn literalType(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    return self.placeType(null, file, node, 0);
}

/// `literalType` in the reading `env` of the function the place is in: each type the place
/// names read with that reading's bindings (a `comptime T: type` parameter's `*T`, the function's
/// result in it, a callee's parameter in the reading the call makes).
pub fn literalTypeIn(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    return self.placeType(env, file, node, 0);
}

/// The type a cast at `node` makes (`@ptrCast`, `@bitCast`), in the reading `env`: its place's
/// (`literalTypeIn`) through the coercions Zig makes to a cast's result location, an error
/// union's payload and then an optional's (`return @ptrCast(p)` in a function returning
/// `Error!?*T` makes a `*T`), in each type the place may be. Unknown where the place is.
pub fn castTypeIn(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    return self.map(try self.literalTypeIn(env, file, node), {}, castPayload);
}

fn castPayload(_: *Facts, place: Value, _: void) ResolveError!Value {
    const inner = if (place == .error_union) place.error_union.* else place;
    return if (inner == .optional) inner.optional.* else inner;
}

/// The type a literal's field `name` takes in a literal of type `whole`, in each type it may be:
/// a literal coerces through an optional or an error union. A field of a container a type
/// function made is read with that call's arguments (`memberOf`). A build that takes a
/// `noreturn` alternative (`.wasi => noreturn`), or a container with no member `name` (a
/// non-Windows `DeviceIoControl` has no `in`), cannot coerce the literal, so that alternative
/// makes no field; where none is left, the field is not known.
fn literalFieldType(self: *Facts, whole: Value, name: []const u8) ResolveError!Value {
    var holder = whole;
    while (true) holder = switch (holder) {
        .optional, .error_union => |inner| inner.*,
        else => break,
    };
    const container = switch (holder) {
        .container, .instance => |c| c,
        .alternatives => |each| {
            var typed: std.ArrayList(Value) = .empty;
            for (each) |one| {
                if (one == .primitive and std.mem.eql(u8, one.primitive, "noreturn")) continue;
                if (self.lacksMember(one, name)) continue;
                try typed.append(self.gpa, one);
            }
            if (typed.items.len == 0) return .{ .unknown = .unsupported };
            const fields = try self.gpa.alloc(Value, typed.items.len);
            for (typed.items, fields) |one, *out| out.* = try self.literalFieldType(one, name);
            return self.choose(fields);
        },
        .unknown => return holder,
        else => return .{ .unknown = .unsupported },
    };
    return self.memberOf(container, self.member(container, name) orelse return .{ .unknown = .unresolved });
}

/// Whether `value`, through an optional or an error union, is a container that declares no
/// member `name`: a literal with a field `name` does not coerce to it.
fn lacksMember(self: *const Facts, value: Value, name: []const u8) bool {
    var holder = value;
    while (true) holder = switch (holder) {
        .optional, .error_union => |inner| inner.*,
        .container, .instance => |c| return self.member(c, name) == null,
        else => return false,
    };
}

fn placeType(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index, depth: usize) ResolveError!Value {
    if (depth == 32) return .{ .unknown = .budget };
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, node)) |literal| if (literal.ast.type_expr.unwrap()) |t| return self.resolveIn(env, file, t);
    const parent = model.parentOf(node) orelse return .{ .unknown = .unsupported };
    if (tree.fullVarDecl(parent)) |variable| {
        if (variable.ast.init_node.unwrap() != node) return .{ .unknown = .unsupported };
        return if (variable.ast.type_node.unwrap()) |t| try self.resolveIn(env, file, t) else .scalar;
    }
    // A field's default value takes the field's type.
    if (model.containerField(tree, parent)) |field| {
        if (field.ast.value_expr.unwrap() != node) return .{ .unknown = .unsupported };
        return if (field.ast.type_expr.unwrap()) |t| try self.resolveIn(env, file, t) else .{ .unknown = .unsupported };
    }
    var call_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, parent)) |call| {
        const position = std.mem.findScalar(Ast.Node.Index, call.ast.params, node) orelse return .{ .unknown = .unsupported };
        return self.parameterType(env, file, parent, call, position);
    }
    var parent_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&parent_buffer, parent) != null) {
        const whole = try self.placeType(env, file, parent, depth + 1);
        if (whole == .unknown or whole == .scalar) return whole;
        const name = try self.memberName(tree.tokenSlice(Model.initName(tree, node) orelse return .{ .unknown = .unsupported }));
        return self.literalFieldType(whole, name);
    }
    if (tree.fullArrayInit(&parent_buffer, parent)) |array| {
        const whole = if (array.ast.type_expr.unwrap()) |t| try self.resolveIn(env, file, t) else try self.placeType(env, file, parent, depth + 1);
        return switch (whole) {
            .array => |each| each.*,
            .unknown => whole,
            else => .{ .unknown = .unsupported },
        };
    }
    switch (tree.nodeTag(parent)) {
        .assign => return if (tree.nodeData(parent).node_and_node[1] == node) try self.resolveIn(env, file, tree.nodeData(parent).node_and_node[0]) else .{ .unknown = .unsupported },
        // `try`, `comptime` and `nosuspend` give their operand their own place (`try`'s
        // operand is the error union around it, read through as a literal's field is).
        .@"try", .@"comptime", .@"nosuspend", .grouped_expression, .@"orelse", .@"catch", .@"if", .if_simple, .@"switch", .switch_comma => return self.placeType(env, file, parent, depth + 1),
        // An operand compared with another (`size != .slice`) takes the other's type: Zig gives
        // both one.
        .equal_equal, .bang_equal => {
            const lhs, const rhs = tree.nodeData(parent).node_and_node;
            return self.typeOf(try self.resolveIn(env, file, if (lhs == node) rhs else lhs), {});
        },
        // An anonymous literal under `&` is what the pointer its place gives points at: a `*T`'s
        // `&.{}` is a `T`; a slice's or a many-item pointer's (a `pointer` to the element too)
        // `&.{ a, b }` an array of the element. Where that element is itself an array, a `*[N]E`
        // and a `[]const [N]E` read alike and the literal is not known.
        .address_of => {
            const target = switch (try self.placeType(env, file, parent, depth + 1)) {
                .pointer => |inner| inner.child.*,
                .unknown => |why| return .{ .unknown = why },
                else => return .{ .unknown = .unsupported },
            };
            var array_buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullArrayInit(&array_buffer, node) == null) return target;
            return switch (target) {
                .array, .alternatives, .unknown => .{ .unknown = .unsupported },
                else => .{ .array = try self.boxed(target) },
            };
        },
        // A case's item takes the type of what the switch tests (`.compare =>` names a tag of
        // the operand's union); its body gives the switch its value.
        .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => {
            if (std.mem.findScalar(Ast.Node.Index, tree.fullSwitchCase(parent).?.ast.values, node) == null) return self.placeType(env, file, parent, depth + 1); // unreachable: the tag is a case's
            const whole = model.parentOf(parent) orelse return .{ .unknown = .unsupported };
            const tested = (tree.fullSwitch(whole) orelse return .{ .unknown = .unsupported }).ast.condition;
            return self.resolveIn(env, file, tested);
        },
        .@"break" => {
            // A `break` with no label leaves the nearest loop; one with a label, the block or
            // loop it names. Each gives that its value.
            const label = tree.nodeData(parent).opt_token_and_opt_node[0].unwrap();
            var at: ?Ast.Node.Index = model.parentOf(parent);
            while (at) |candidate| : (at = model.parentOf(candidate)) {
                const loop = tree.fullWhile(candidate) != null or tree.fullFor(candidate) != null;
                const name = label orelse {
                    if (loop) return self.placeType(env, file, candidate, depth + 1);
                    continue;
                };
                const tag = tree.nodeTag(candidate);
                // A labeled block's brace follows its label and a colon, as a labeled loop's
                // first token does.
                const start = if (loop) tree.firstToken(candidate) else if (tag == .block or tag == .block_semicolon or tag == .block_two or tag == .block_two_semicolon) tree.nodeMainToken(candidate) else continue;
                if (start >= 2 and tree.tokenTag(start - 1) == .colon and std.mem.eql(u8, tree.tokenSlice(start - 2), tree.tokenSlice(name))) return self.placeType(env, file, candidate, depth + 1);
            }
            return .{ .unknown = .unsupported };
        },
        // A loop's `else` gives the loop's value.
        .@"for", .for_simple, .@"while", .while_simple, .while_cont => {
            const otherwise = if (tree.fullFor(parent)) |loop| loop.ast.else_expr else tree.fullWhile(parent).?.ast.else_expr; // unreachable: the tag is a loop's
            return if (otherwise.unwrap() == node) self.placeType(env, file, parent, depth + 1) else .{ .unknown = .unsupported };
        },
        .@"return" => {
            var at: ?Ast.Node.Index = model.parentOf(parent);
            while (at) |candidate| : (at = model.parentOf(candidate)) {
                if (tree.nodeTag(candidate) != .fn_decl) continue;
                var fn_buffer: [1]Ast.Node.Index = undefined;
                const function = tree.fullFnProto(&fn_buffer, tree.nodeData(candidate).node_and_node[0]) orelse return .{ .unknown = .unsupported };
                const result = function.ast.return_type.unwrap() orelse return .{ .unknown = .unsupported };
                return self.resolveIn(env, file, result);
            }
            return .{ .unknown = .unsupported };
        },
        else => {},
    }
    var args_buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, parent, &args_buffer);
    if (args.len == 2 and args[1] == node and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parent)), "@as")) return self.resolveIn(env, file, args[0]);
    return .{ .unknown = .unsupported };
}

/// The written type of a call's argument at `position`: the callee's parameter (a method's
/// receiver first), a made container's method read with the arguments that made it.
/// `.scalar` for `anytype`, which takes the argument's own type.
fn parameterType(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index, call: Ast.full.Call, position: usize) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const callee = try self.resolveIn(env, file, call.ast.fn_expr);
    if (callee == .unknown) return callee;
    // A call through a function pointer whose functions are not all seen (a table firmware
    // fills, a callback handed in): the parameter its type declares, which binds no receiver.
    if (callee != .function) {
        var typed = callee;
        while (true) typed = switch (typed) {
            .pointer => |inner| inner.child.*,
            .optional => |inner| inner.*,
            else => break,
        };
        return if (typed == .fn_type) self.fnTypeParameter(typed.fn_type, position) else .{ .unknown = .unsupported };
    }
    const decl = callee.function;
    var receiver: usize = 0;
    var made: ?*const Made = null;
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        const on = try self.resolveIn(env, file, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
        const container: ?Container = switch (on) {
            .instance => |c| c,
            .pointer => |p| switch (p.child.*) {
                .instance => |c| c,
                else => null,
            },
            else => null,
        };
        if (container) |c| {
            receiver = 1;
            if (c.made_by) |m| if (decl.file == c.file and self.project.at(decl.file).model.declarations[@backingInt(decl.index)].scope == c.scope) {
                made = m;
            };
        }
        // A function of a made type called on the type (`Atomic(T).init(x)`): its bindings.
        if (on == .container) if (on.container.made_by) |m| if (decl.file == on.container.file and self.project.at(decl.file).model.declarations[@backingInt(decl.index)].scope == on.container.scope) {
            made = m;
        };
    }
    // A declaration literal's call (`.init(x)`) is a function of the type its place takes.
    if (tree.nodeTag(call.ast.fn_expr) == .enum_literal) {
        var place = try self.placeType(env, file, node, 1);
        while (true) place = switch (place) {
            .pointer => |inner| inner.child.*,
            .optional, .error_union => |inner| inner.*,
            else => break,
        };
        switch (place) {
            .container, .instance => |c| if (c.made_by) |m| if (decl.file == c.file and self.project.at(decl.file).model.declarations[@backingInt(decl.index)].scope == c.scope) {
                made = m;
            },
            else => {},
        }
    }
    const target_tree = &self.project.at(decl.file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, self.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return .{ .unknown = .unsupported };
    var it = function.iterate(target_tree);
    var at: usize = 0;
    while (it.next()) |param| : (at += 1) {
        if (at < receiver or at - receiver != position) continue;
        const type_expr = param.type_expr orelse return .scalar;
        // In a reading: the parameter's type in the reading the call makes, which binds its
        // generic parameters, a made container's arguments and the receiver.
        if (env != null) return self.resolveIn(try self.bind(file, call, decl, env), decl.file, type_expr);
        if (made) |m| return self.substituted(decl.file, type_expr, m);
        // Written in terms of a `comptime T: type` parameter: the call's argument for it.
        if (try self.written(.{ .file = file, .call = call, .decl = decl, .function = function, .receiver = receiver }, type_expr, 0)) |bound| return bound;
        return self.resolve(decl.file, type_expr);
    }
    return .{ .unknown = .unsupported };
}

/// The type a function type written at `key` gives its parameter at `position`; unknown where
/// it has none there.
fn fnTypeParameter(self: *Facts, key: Key, position: usize) ResolveError!Value {
    const tree = self.syntaxOf(key.file);
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, key.node) orelse return .{ .unknown = .unsupported };
    var it = proto.iterate(tree);
    var at: usize = 0;
    while (it.next()) |param| : (at += 1) {
        if (at != position) continue;
        return if (param.type_expr) |type_expr| self.resolve(key.file, type_expr) else .scalar;
    }
    return .{ .unknown = .unsupported };
}

test "a pointer cast that keeps what it points at gives its operand: @alignCast, @constCast, @volatileCast, @addrSpaceCast" {
    const source =
        \\const Foo = struct { a: u8 };
        \\var foo: Foo = .{ .a = 1 };
        \\pub fn main(ctx: *anyopaque) void {
        \\    const p: *const Foo = &foo;
        \\    const aligned: *align(1) const Foo = @alignCast(p);
        \\    const mutable: *Foo = @constCast(p);
        \\    const volatile_: *volatile const Foo = @volatileCast(p);
        \\    const spaced: *const Foo = @addrSpaceCast(p);
        \\    const back: *Foo = @ptrCast(@alignCast(ctx));
        \\    _ = .{ aligned, mutable, volatile_, spaced, back };
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable;
        }
    };
    const foo = try facts.resolve(file, node.of(tree, "Foo"));
    // Each a pointer to `Foo`, as `p` is.
    for ([_][]const u8{ "@alignCast(p)", "@constCast(p)", "@volatileCast(p)", "@addrSpaceCast(p)" }) |cast| {
        const value = try facts.resolve(file, node.of(tree, cast));
        try std.testing.expect(value == .pointer and value.pointer.child.* == .instance and value.pointer.child.instance.scope == foo.container.scope);
    }
    // An opaque pointer's alignment changed points at the opaque still: no type it is not.
    const opaque_ = try facts.resolve(file, node.of(tree, "@alignCast(ctx)"));
    const ctx = try facts.resolve(file, node.of(tree, "ctx"));
    try std.testing.expect(ctx == .pointer and opaque_ == .pointer);
    try std.testing.expectEqual(std.meta.activeTag(ctx.pointer.child.*), std.meta.activeTag(opaque_.pointer.child.*));
}

test "a place's type in a reading reads the reading's bindings: a declaration's, a return's and @as's type written in terms of a comptime type parameter" {
    const source =
        \\const Foo = struct { a: u8 };
        \\fn raw() *anyopaque { return undefined; }
        \\fn create(comptime T: type) *T {
        \\    const ptr: *T = @ptrCast(@alignCast(raw()));
        \\    _ = ptr;
        \\    const many = @as([*]T, @ptrCast(@alignCast(raw())));
        \\    _ = many;
        \\    return @ptrCast(@alignCast(raw()));
        \\}
        \\const Bar = struct { b: u16 };
        \\pub fn main() void { _ = create(Foo); _ = create(Bar); }
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const root = facts.rootOf(file);
    const node = struct {
        fn of(t: *const Ast, text: []const u8, nth: usize) Ast.Node.Index {
            var left = nth;
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (!std.mem.eql(u8, t.getNodeSource(at), text)) continue;
                if (left == 0) return at;
                left -= 1;
            }
            unreachable;
        }
    };
    var buffer: [1]Ast.Node.Index = undefined;
    const reading = try facts.bind(file, tree.fullCall(&buffer, node.of(tree, "create(Foo)", 0)).?, facts.member(root, "create").?, null);
    const foo = try facts.resolve(file, node.of(tree, "Foo", 0));
    const cast = "@ptrCast(@alignCast(raw()))";
    // The declaration's `*T`, `@as`'s `[*]T` and the function's result `*T`, each `Foo` in
    // `create(Foo)`'s reading, not either of the two types its calls give.
    for (0..3) |nth| {
        const place = try facts.literalTypeIn(reading, file, node.of(tree, cast, nth));
        try std.testing.expect(place == .pointer and place.pointer.child.* == .container and place.pointer.child.container.scope == foo.container.scope);
    }
}

test "a container a forwarding type function makes is read with the outer call's bindings" {
    const source =
        \\const Payload = struct { value: u64 };
        \\fn release(p: *Payload) void { _ = p; }
        \\fn Owner(comptime T: type, comptime with_io: bool, comptime cleanup: if (with_io) fn (*T, u8) void else fn (*T) void) type {
        \\    return struct { const Self = @This(); comptime { _ = cleanup; } data: T, pub fn initFrom(source: *T) Self { return .{ .data = source.* }; } pub fn borrowMut(self: *Self) *T { return &self.data; } };
        \\}
        \\pub fn Owned(comptime T: type, comptime cleanup: fn (*T) void) type { return Owner(T, false, cleanup); }
        \\const Held = Owned(Payload, release);
        \\pub fn f(source: *Payload) void { var owner = Held.initFrom(source); const p = owner.borrowMut(); _ = p; }
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const model = &project.sources[0].model;
    const p = for (model.declarations) |d| {
        if (d.kind == .variable and std.mem.eql(u8, d.name, "p")) break d;
    } else unreachable; // unreachable: the source declares `p`
    const init = project.sources[0].file.tree.fullVarDecl(p.node).?.ast.init_node.unwrap().?;
    const value = try facts.resolve(project.sources[0].id, init);
    try std.testing.expect(value == .pointer);
    try std.testing.expect(value.pointer.child.* == .instance);
}

test "an error value among a block's breaks makes the others an error union, as null makes them optional" {
    const source =
        \\const Status = struct { entries: []const u8 };
        \\fn status() !Status { return .{ .entries = "" }; }
        \\pub fn f(bare: bool) void {
        \\    const changes = deploy: {
        \\        if (bare) break :deploy error.BareRepository;
        \\        break :deploy status();
        \\    };
        \\    const s = changes catch return;
        \\    const maybe = if (bare) null else status() catch return;
        \\    const either = if (bare) error.Bare else Status{ .entries = "" };
        \\    _ = .{ s, maybe, either };
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const model = &project.sources[0].model;
    var found: [3]Value = undefined;
    for ([_][]const u8{ "s", "maybe", "either" }, &found) |name, *out| {
        const d = for (model.declarations) |d| {
            if (d.kind == .variable and std.mem.eql(u8, d.name, name)) break d;
        } else unreachable; // unreachable: the source declares each name
        out.* = try facts.resolve(project.sources[0].id, project.sources[0].file.tree.fullVarDecl(d.node).?.ast.init_node.unwrap().?);
    }
    try std.testing.expect(found[0] == .instance);
    try std.testing.expect(found[1] == .optional and found[1].optional.* == .instance);
    try std.testing.expect(found[2] == .error_union and found[2].error_union.* == .instance);
}

test "@errorReturnTrace and @src give std's own types where the project maps std" {
    const source =
        \\const std = @import("std");
        \\pub fn f() void {
        \\    const here = @src();
        \\    if (@errorReturnTrace()) |trace| {
        \\        const held = trace;
        \\        _ = .{ held, here };
        \\    }
        \\}
    ;
    const lang = "pub const StackTrace = struct { index: usize };\npub const SourceLocation = struct { line: u32 };\n";
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = source },
        .{ .name = "std/std.zig", .bytes = "pub const lang = @import(\"lang.zig\");\npub const builtin = lang;\n", .selected = false },
        .{ .name = "std/lang.zig", .bytes = lang, .selected = false },
    }, &.{
        .{ .from = 0, .spelling = "std", .target = 1 },
        .{ .from = 1, .spelling = "lang.zig", .target = 2 },
    }, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const model = &project.sources[0].model;
    var found: [2]Value = undefined;
    for ([_][]const u8{ "held", "here" }, &found) |name, *out| {
        const d = for (model.declarations) |d| {
            if (d.kind == .variable and std.mem.eql(u8, d.name, name)) break d;
        } else unreachable; // unreachable: the source declares each name
        out.* = try facts.resolve(project.sources[0].id, project.sources[0].file.tree.fullVarDecl(d.node).?.ast.init_node.unwrap().?);
    }
    try std.testing.expect(found[0] == .pointer and found[0].pointer.child.* == .instance and found[0].pointer.child.instance.file == project.sources[2].id);
    try std.testing.expect(found[1] == .instance and found[1].instance.file == project.sources[2].id);
}

test "an entry a made container's iterator gives is read with the container's bindings" {
    // The map is a library's, as std's is: its iterator's `next` gives an `Entry` declared
    // beside the iterator in what the call made, not inside it.
    const library =
        \\pub fn Map(comptime K: type, comptime V: type, comptime Ctx: type, comptime load: u64) type {
        \\    return struct {
        \\        const Self = @This();
        \\        comptime { _ = Ctx; _ = load; }
        \\        pub const Entry = struct { key_ptr: *K, value_ptr: *V };
        \\        pub const Iterator = struct { m: *const Self, index: u32 = 0, pub fn next(it: *Iterator) ?Entry { if (it.m.size == 0) return null; const key = &it.m.keys()[it.index]; const value = &it.m.values()[it.index]; return Entry{ .key_ptr = key, .value_ptr = value }; } };
        \\        size: u32 = 0,
        \\        fn keys(self: Self) [*]K { _ = self; return undefined; }
        \\        fn values(self: Self) [*]V { _ = self; return undefined; }
        \\        pub fn iterator(self: *const Self) Iterator { return .{ .m = self }; }
        \\    };
        \\}
        \\fn Context(comptime K: type) type { return struct { pub fn hash(self: @This(), key: K) u64 { _ = self; _ = key; return 0; } }; }
        \\const default_load = 80;
        \\pub fn Auto(comptime K: type, comptime V: type) type { return Map(K, V, Context(K), default_load); }
    ;
    const source =
        \\const lib = @import("lib");
        \\const Id = enum(u32) { a };
        \\const M = lib.Auto(Id, u32);
        \\pub fn f(m: *M) void { var it = m.iterator(); const e = it.next().?; const k = e.key_ptr.*; const i = it; _ = .{ k, i }; }
    ;
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = source },
        .{ .name = "lib/lib.zig", .bytes = library, .selected = false },
    }, &.{.{ .from = 0, .spelling = "lib", .target = 1 }}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const model = &project.sources[0].model;
    var found: [3]Value = undefined;
    for ([_][]const u8{ "i", "e", "k" }, &found) |name, *out| {
        const d = for (model.declarations) |d| {
            if (d.kind == .variable and std.mem.eql(u8, d.name, name)) break d;
        } else unreachable; // unreachable: the source declares each name
        out.* = try facts.resolve(project.sources[0].id, project.sources[0].file.tree.fullVarDecl(d.node).?.ast.init_node.unwrap().?);
    }
    try std.testing.expect(found[0] == .instance);
    try std.testing.expect(found[1] == .instance);
    try std.testing.expect(found[2] == .instance);
}

test "a made container's method whose result names its own generic parameter is read with each call's argument" {
    const library =
        \\pub fn Untrusted(comptime T: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        value: T,
        \\        pub fn init(value: T) Self { return .{ .value = value }; }
        \\        pub fn parse(self: Self, context: anytype, comptime parser: anytype) Result(parser) { return parser(context, self.value); }
        \\        fn Result(comptime parser: anytype) type {
        \\            const info = @typeInfo(@TypeOf(parser));
        \\            const R = info.@"fn".return_type.?;
        \\            return R;
        \\        }
        \\    };
        \\}
    ;
    const source =
        \\const input = @import("input");
        \\const Header = struct { n: u32 };
        \\const Body = struct { bytes: []const u8 };
        \\fn header(c: u8, bytes: []const u8) error{Bad}!Header { _ = c; _ = bytes; return .{ .n = 1 }; }
        \\fn body(c: u8, bytes: []const u8) error{Bad}!Body { _ = c; return .{ .bytes = bytes }; }
        \\pub fn f(bytes: []const u8) !void {
        \\    const h = try input.Untrusted([]const u8).init(bytes).parse(@as(u8, 0), header);
        \\    const b = try input.Untrusted([]const u8).init(bytes).parse(@as(u8, 0), body);
        \\    _ = .{ h, b };
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = source },
        .{ .name = "input/input.zig", .bytes = library, .selected = false },
    }, &.{.{ .from = 0, .spelling = "input", .target = 1 }}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const model = &project.sources[0].model;
    var found: [2]Value = undefined;
    for ([_][]const u8{ "h", "b" }, &found) |name, *out| {
        const d = for (model.declarations) |d| {
            if (d.kind == .variable and std.mem.eql(u8, d.name, name)) break d;
        } else unreachable; // unreachable: the source declares each name
        out.* = try facts.resolve(project.sources[0].id, project.sources[0].file.tree.fullVarDecl(d.node).?.ast.init_node.unwrap().?);
    }
    // Each is its own parser's result, not a choice among every call's.
    try std.testing.expect(found[0] == .instance);
    try std.testing.expect(found[1] == .instance);
    try std.testing.expect(found[0].instance.scope != found[1].instance.scope);
}

/// What `o.run` in `source` names, where a call calls it (`called`) or is read as a value: a
/// function, a choice of them, or the field's type alone (any); the program `source` alone.
const FieldRead = enum { function, choice, any };
fn fieldRead(source: []const u8, called_there: bool) !FieldRead {
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .field_access or !std.mem.eql(u8, tree.getNodeSource(node), "o.run")) continue;
        if (called(tree, &project.sources[0].model, node) != called_there) continue;
        var value = try facts.resolve(project.sources[0].id, node);
        while (value == .pointer) value = value.pointer.child.*;
        return switch (value) {
            .function => .function,
            .alternatives => .choice,
            else => .any,
        };
    }
    unreachable; // unreachable: each source spells `o.run` both ways
}

test "a call through a function-pointer field reaches the functions stored there, only where every store is seen" {
    const head =
        \\const Ops = struct { run: *const fn (u32) u32 };
        \\fn a(x: u32) u32 { return x; }
        \\fn b(x: u32) u32 { return x + 1; }
        \\pub const one: Ops = .{ .run = a };
        \\pub fn f(o: *const Ops) u32 { return o.run(1); }
        \\pub fn h(o: *const Ops) usize { return @intFromPtr(o.run); }
        \\
    ;
    // Stored by a literal and an assignment, each a function: one, or a choice of them, called
    // or read as a value.
    try std.testing.expectEqual(.function, try fieldRead(head, true));
    try std.testing.expectEqual(.choice, try fieldRead(head ++ "pub fn g(o: *Ops) void { o.run = &b; }\n", true));
    try std.testing.expectEqual(.function, try fieldRead(head, false));
    // Unresolved: a value chosen at run time, the field's address taken, a file not read.
    try std.testing.expectEqual(.any, try fieldRead(head ++ "pub fn g(o: *Ops, run: *const fn (u32) u32) void { o.run = run; }\n", true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ "pub fn g(o: *Ops) *const *const fn (u32) u32 { return &o.run; }\n", true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ "const missing = @import(\"missing\");\npub fn g() void { _ = missing; }\n", true));
    // A reflective write: by a name that ranges over another struct's fields, not this one's; by
    // any other name, it may be.
    try std.testing.expectEqual(.function, try fieldRead(head ++ "const Other = struct { x: u32 };\npub fn g(o: *Ops) void { inline for (@typeInfo(Other).@\"struct\".field_names) |n| @field(o, n) = b; }\n", true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ "pub fn g(o: *Ops, comptime n: []const u8) void { @field(o, n) = &b; }\n", true));
    // Stored by a destructure, each construct `Facts.accesses` reads: a function it may hold, or
    // a value chosen at run time; and its struct's memory written through a cast of it.
    try std.testing.expectEqual(.choice, try fieldRead(head ++ "pub fn g(o: *Ops) void { o.run, _ = .{ &b, 0 }; }\n", true));
    try std.testing.expectEqual(.function, try fieldRead(head ++ "pub fn g(o: *Ops) void { _, _ = .{ &b, 0 }; _ = o; }\n", true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ "pub fn g(o: *Ops, run: *const fn (u32) u32) void { o.run, _ = .{ run, 0 }; }\n", true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ "pub fn g(o: *Ops) *[8]u8 { return @ptrCast(o); }\n", true));
    try std.testing.expectEqual(.function, try fieldRead(head ++ "const Other = struct { x: u64 };\npub fn g(o: *Other) *[8]u8 { return @ptrCast(o); }\n", true));
    // A type built from its fields' types (std's Io.Operation.Result, an `@Union`) holds what
    // they do: a struct of a `u64` no Ops, a struct of an Ops one.
    try std.testing.expectEqual(.function, try fieldRead(head ++ "const Built = @Struct(.auto, null, &.{\"x\"}, &.{u64}, &@splat(.{}));\npub fn g(o: *Built) *[8]u8 { return @ptrCast(o); }\n", true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ "const Built = @Struct(.auto, null, &.{\"x\"}, &.{Ops}, &@splat(.{}));\npub fn g(o: *Built) *[8]u8 { return @ptrCast(o); }\n", true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ "const Built = @Struct(.auto, null, &.{ \"x\", \"y\" }, &.{ u64, Ops }, &@splat(.{}));\npub fn g(o: *Built) *[16]u8 { return @ptrCast(o); }\n", true));
    // A cast returned as an error union's or an optional's payload views what the payload
    // points at.
    try std.testing.expectEqual(.any, try fieldRead(head ++ "pub fn g(bytes: *[8]u8) error{E}!*Ops { return @ptrCast(bytes); }\n", true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ "pub fn g(bytes: *[8]u8) error{E}!?*Ops { return @ptrCast(bytes); }\n", true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ "pub fn g(bytes: *[8]u8) ?*Ops { return @ptrCast(bytes); }\n", true));
    try std.testing.expectEqual(.function, try fieldRead(head ++ "const Other = struct { x: u64 };\npub fn g(bytes: *[8]u8) error{E}!*Other { return @ptrCast(bytes); }\n", true));
    // A cast given a declaration literal's call takes its parameter's type, the function read in
    // the type the call's place points at (std's SafeAllocator `const b: *Bucket = .of(s,
    // @ptrCast(f))`): bytes, no Ops; a parameter of `*Ops` views one.
    const bucket = "const Footer = struct { y: u64 };\nconst Bucket = struct {\n    x: u64,\n    fn of(ptr: [*]u8) *Bucket { return @ptrFromInt(@intFromPtr(ptr)); }\n    fn ofOps(o: *Ops) *Bucket { return @ptrFromInt(@intFromPtr(o)); }\n};\n";
    try std.testing.expectEqual(.function, try fieldRead(head ++ bucket ++ "pub fn g(ft: *Footer) void { const held: *Bucket = .of(@ptrCast(ft)); _ = held; }\n", true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ bucket ++ "pub fn g(ft: *Footer) void { const held: *Bucket = .ofOps(@ptrCast(ft)); _ = held; }\n", true));
    // Handed to a call through a function pointer whose functions are not all seen (a table
    // firmware fills: std's UEFI `self._exit(..., @ptrCast(msg.ptr))`), a cast takes the
    // parameter the pointer's function type declares: a `?[*]const u16`, no Ops; a `*Ops`, one.
    const table = "pub fn set(t: *Table, cb: @FieldType(Table, \"cb\")) void { t.cb = cb; }\npub fn g(t: *Table, w: [:0]const u16) void { t.cb(@ptrCast(w.ptr)); }\n";
    try std.testing.expectEqual(.function, try fieldRead(head ++ "const Table = struct { cb: *const fn (?[*]const u16) void };\n" ++ table, true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ "const Table = struct { cb: *const fn (*Ops) void };\n" ++ table, true));
    // A type function's member, generic itself, reached by its name alone (std's
    // `TrailerFlags(F).ptr` through a `.ptr` read off a value whose type does not resolve):
    // no instance exists while nothing reaches the type function, so its cast views nothing.
    // Reached, it is read in each of its readings: `Flags(Ops)`'s cast views Ops, `Flags(u64)`'s
    // does not; handed as a value and evaluated only inside another function, it is reached by
    // the mention.
    const flags = "fn Flags(comptime F: type) type {\n    return struct {\n        fn ptr(p: [*]u8, comptime field: u8) *F {\n            _ = field;\n            return @ptrCast(@alignCast(p));\n        }\n    };\n}\npub fn g(x: anytype) void { _ = x.ptr; }\n";
    try std.testing.expectEqual(.function, try fieldRead(head ++ flags, true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ flags ++ "pub fn k(bytes: [*]u8) void { _ = Flags(Ops).ptr(bytes, 0); }\n", true));
    try std.testing.expectEqual(.function, try fieldRead(head ++ flags ++ "pub fn k(bytes: [*]u8) void { _ = Flags(u64).ptr(bytes, 0); }\n", true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ flags ++ "fn mk(comptime M: fn (type) type) type { return M(Ops); }\npub const T = mk(Flags);\n", true));
    // Named by a computed `@field` of its namespace, it is reached as each member that name may be.
    const in_mod = "const mod = struct {\n    fn Flags(comptime F: type) type {\n        return struct {\n            fn ptr(p: [*]u8, comptime field: u8) *F {\n                _ = field;\n                return @ptrCast(@alignCast(p));\n            }\n        };\n    }\n};\npub fn g(x: anytype) void { _ = x.ptr; }\n";
    try std.testing.expectEqual(.function, try fieldRead(head ++ in_mod, true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ in_mod ++ "pub fn mkBy(comptime name: []const u8) type { return @field(mod, name)(Ops); }\n", true));
    // A pointer cast keeps `const`: the bytes of a parameter's address, or of a copy's handed
    // where a `[]const u8` goes, are read, never written; through `[]u8` or `@constCast`, they
    // may be.
    const sink = "fn read(_: []const u8) void {}\nfn write(_: []u8) void {}\n";
    try std.testing.expectEqual(.function, try fieldRead(head ++ sink ++ "pub fn g(o: Ops) void { read(@ptrCast((&o)[0..1])); }\n", true));
    try std.testing.expectEqual(.function, try fieldRead(head ++ sink ++ "pub fn g(o: *const Ops) void { var copy = o.*; read(@ptrCast((&copy)[0..1])); }\n", true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ sink ++ "pub fn g(o: *const Ops) void { var copy = o.*; write(@ptrCast((&copy)[0..1])); }\n", true));
    try std.testing.expectEqual(.any, try fieldRead(head ++ sink ++ "pub fn g(o: Ops) void { write(@ptrCast(@constCast((&o)[0..1]))); }\n", true));
}

test "boundInRun: a generic is bound where compiled code calls it, a test or a function that is no generic, or a generic itself bound; one bound only in an unbound generic is not" {
    const source = "pub fn lone(x: anytype) void { _ = x; }\npub fn used(x: anytype) void { _ = x; }\npub fn tested(x: anytype) void { _ = x; }\npub fn inner(x: anytype) void { _ = x; }\npub fn outer(x: anytype) void { inner(x); }\npub fn main() void { used(@as(u8, 1)); }\ntest \"tested\" { tested(@as(u8, 2)); }";
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const root = facts.rootOf(project.sources[0].id);
    try std.testing.expectEqual(@as(?bool, false), try facts.boundInRun(facts.member(root, "lone").?));
    try std.testing.expectEqual(@as(?bool, true), try facts.boundInRun(facts.member(root, "used").?));
    try std.testing.expectEqual(@as(?bool, true), try facts.boundInRun(facts.member(root, "tested").?));
    // `inner` is called only in `outer`, a generic nothing compiled binds.
    try std.testing.expectEqual(@as(?bool, false), try facts.boundInRun(facts.member(root, "inner").?));
}

test "bindCall binds f(a), x.f(a) with its receiver, T.f(a) and @call's tuple, and makes no reading of arguments not known" {
    const source = "const S = struct { n: u8 = 0, pub fn get(s: S, k: anytype) u8 { _ = k; return s.n; } pub fn of(k: anytype) u8 { _ = k; return 0; } };\npub fn f(k: anytype) u8 { _ = k; return 1; }\npub fn main(t: anytype) void { const s: S = .{}; _ = f(s); _ = s.get(s); _ = S.of(s); _ = @call(.auto, f, .{s}); _ = @call(.auto, f, t); }";
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const root = facts.rootOf(file);
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable;
        }
    };
    const f = facts.member(root, "f").?;
    const s_type = (try facts.resolve(file, node.of(tree, "S"))).container;
    const get = facts.member(s_type, "get").?;
    const of = facts.member(s_type, "of").?;
    // Each binds its one argument, `s`, an `S`; `x.f(a)` binds `s` first as its receiver.
    for ([_]struct { []const u8, Decl, usize }{ .{ "f(s)", f, 1 }, .{ "s.get(s)", get, 2 }, .{ "S.of(s)", of, 1 }, .{ "@call(.auto, f, .{s})", f, 1 } }) |row| {
        const text, const function, const len = row;
        const call = (try calls.at(&facts, file, node.of(tree, text))).?;
        const reading = (try facts.bindCall(&call, function, null)).reading;
        try std.testing.expectEqual(len, reading.args.len);
        for (reading.args) |arg| try std.testing.expect(arg == .instance);
    }
    // A tuple not written: its elements are not known, so no reading is made.
    const unknown = (try calls.at(&facts, file, node.of(tree, "@call(.auto, f, t)"))).?;
    try std.testing.expect(try facts.bindCall(&unknown, f, null) == .unknown);
}

test "a reading bound call by call reads a generic's value as the chain of calls passes it" {
    const source = "const S = struct { pub fn format(_: S) void {} };\npub fn print(value: anytype) void { show(value); }\npub fn show(v: anytype) void { v.format(); }\npub fn main() void { print(S{}); }";
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const model = &project.sources[0].model;
    const file = project.sources[0].id;
    const named = struct {
        fn function(m: *const Model, name: []const u8) Decl {
            for (m.declarations, 0..) |d, i| if (d.kind == .function and std.mem.eql(u8, d.name, name)) return .{ .file = @fromBackingInt(0), .index = @fromBackingInt(@intCast(i)) };
            unreachable;
        }
        fn call(t: *const Ast, callee: []const u8) Ast.Node.Index {
            for (t.nodes.items(.tag), 0..) |tag, i| switch (tag) {
                .call_one, .call_one_comma => {
                    const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                    const f = t.nodeData(node).node_and_opt_node[0];
                    if (t.nodeTag(f) == .identifier and std.mem.eql(u8, t.tokenSlice(t.nodeMainToken(f)), callee)) return node;
                },
                else => {},
            };
            unreachable;
        }
    };
    var buffer: [1]Ast.Node.Index = undefined;
    const outer = try facts.bind(file, tree.fullCall(&buffer, named.call(tree, "print")).?, named.function(model, "print"), null);
    const inner = try facts.bind(file, tree.fullCall(&buffer, named.call(tree, "show")).?, named.function(model, "show"), outer);
    // `v` in `show`, as `main` → `print` → `show` passes it: an `S`, whose `format` is found.
    const v = for (model.declarations) |d| {
        if (d.kind == .parameter and std.mem.eql(u8, d.name, "v")) break d;
    } else unreachable;
    var use: ?Ast.Node.Index = null;
    for (tree.nodes.items(.tag), 0..) |tag, i| if (tag == .identifier) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "v") and tree.nodeMainToken(node) != v.token) use = node;
    };
    const value = try facts.resolveBound(inner, file, use.?);
    try std.testing.expect(value == .instance);
    try std.testing.expect(facts.member(value.instance, "format") != null);
    // Unbound, the same `v` of a public generic is each binding's.
    try std.testing.expectEqual(Unknown.generic, (try facts.resolve(file, use.?)).unknown);
}

test "a function handed to code outside the program as a value escapes: its callers are not all the program's" {
    // `less` is handed to a known library's `sort`, which may call it with anything; `twice`
    // is only called, and every call the program makes shows what it is given.
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = "const lib = @import(\"lib\");\nfn less(a: u8, b: u8) bool {\n    return a < b;\n}\nfn twice(a: u8) u8 {\n    return a *% 2;\n}\npub fn f(x: u8) u8 {\n    lib.sort(less);\n    return twice(x);\n}" },
        .{ .name = "lib", .bytes = "pub fn sort(comptime order: anytype) void {\n    _ = order;\n}", .selected = false, .package = "lib", .fingerprint = 1 },
    }, &.{.{ .from = 0, .spelling = "lib", .target = 1 }}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator(), .known = .{ .name = "lib", .fingerprint = 1 } };
    defer facts.deinit();
    const model = &project.sources[0].model;
    var less: ?Decl = null;
    var twice: ?Decl = null;
    var entry: ?Decl = null;
    for (model.declarations, 0..) |decl, i| {
        const id: Decl = .{ .file = project.sources[0].id, .index = @fromBackingInt(@intCast(i)) };
        if (std.mem.eql(u8, decl.name, "less")) less = id;
        if (std.mem.eql(u8, decl.name, "twice")) twice = id;
        if (std.mem.eql(u8, decl.name, "f")) entry = id;
    }
    try std.testing.expect(try facts.escapes(less.?));
    try std.testing.expect(!try facts.escapes(twice.?));
    // Only `less` is handed out to be called with anything: `f` is called by its name alone.
    try std.testing.expect(try facts.handedOut(less.?));
    try std.testing.expect(!try facts.handedOut(entry.?) and !try facts.handedOut(twice.?));
}

test "a slice of what does not resolve is a slice: its `.len` is its count, never a field" {
    // `p` is `anytype`: whatever it is, slicing it gives a slice or a pointer to an array, and
    // `.len` there counts its elements (any `usize`: they may take no room).
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes =
        \\fn f(p: anytype, n: usize) usize {
        \\    const s = p[0..n];
        \\    return s.len;
        \\}
    }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    var len: ?Ast.Node.Index = null;
    var slice: ?Ast.Node.Index = null;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tag == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(node).node_and_token[1]), "len")) len = node;
        if (tag == .slice) slice = node;
    }
    const sliced_value = try facts.resolve(file, slice.?);
    try std.testing.expect(sliced_value == .pointer);
    try std.testing.expectEqual(Size.slice, sliced_value.pointer.size.?);
    try std.testing.expectEqual(Length.unsized, try facts.memoryField(file, len.?));
}

test "a parameter's type has a length where it is or holds memory that has one" {
    // A slice, an array, a pointer to one, a struct holding a slice (through a pointer or an
    // optional, or itself), memory a cast may give any type, and a type that does not resolve
    // have one; a number, `bool`, an enum, an error set, a pointer to a number, and a struct of
    // those (one reaching itself among them) have none.
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes =
        \\const Color = enum { red, blue };
        \\const Pair = struct { a: u32, b: ?bool };
        \\const Node = struct { next: ?*Node, value: u64 };
        \\const Held = struct { items: []u8, count: usize };
        \\const Bytes = []const u8;
        \\const Missing = @import("missing").Missing;
        \\fn f(
        \\    a: u32,
        \\    b: bool,
        \\    c: Color,
        \\    d: error{Fail},
        \\    e: *const u32,
        \\    g: ?u64,
        \\    h: Pair,
        \\    i: *Node,
        \\    j: []const u8,
        \\    k: [4]u8,
        \\    l: *const [4]u8,
        \\    m: Held,
        \\    n: ?*const Held,
        \\    o: Bytes,
        \\    p: *anyopaque,
        \\    q: Missing,
        \\) void {
        \\    _ = .{ a, b, c, d, e, g, h, i, j, k, l, m, n, o, p, q };
        \\}
    }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const model = &project.sources[0].model;
    var proto: ?Ast.full.FnProto = null;
    var buffer: [1]Ast.Node.Index = undefined;
    for (model.declarations) |decl| if (decl.kind == .function and std.mem.eql(u8, decl.name, "f")) {
        proto = tree.fullFnProto(&buffer, decl.node);
    };
    var seen: std.ArrayList(u8) = .empty;
    var it = proto.?.iterate(tree);
    while (it.next()) |param| if (try facts.holdsLength(project.sources[0].id, param.type_expr.?)) try seen.appendSlice(arena.allocator(), tree.tokenSlice(param.name_token.?));
    try std.testing.expectEqualStrings("jklmnopq", seen.items);
}

test "a library's call through a field whose type names none of its generic's parameters calls none of the program's functions" {
    // `lock`'s type does not resolve (a type a generic makes), but the library declares it
    // with no parameter of its own: its `load` is the library's. `ctx` is the parameter's, and
    // may be the program's value, whose `hash` the library then calls where the program reaches
    // that call (`use`, with a context any consumer may give).
    const lib =
        \\pub fn Value(comptime T: type) type {
        \\    return struct { raw: T, pub fn load(self: @This()) T { return self.raw; } };
        \\}
        \\pub fn Guarded(comptime T: type) type {
        \\    return struct {
        \\        lock: Value(bool),
        \\        data: T,
        \\        pub fn spin(owner: *@This()) bool { return owner.lock.load(); }
        \\        pub fn peek(owner: *@This()) bool { const held = (&owner.lock); return held.load(); }
        \\    };
        \\}
        \\pub fn Table(comptime Context: type) type {
        \\    return struct {
        \\        ctx: Context,
        \\        pub fn find(self: *@This()) u32 { return self.ctx.hash(); }
        \\    };
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = "const lib = @import(\"lib\");\npub fn load(x: u8) u8 {\n    return x;\n}\npub fn hash(x: u8) u8 {\n    return x;\n}\npub fn use(comptime C: type, t: *lib.Table(C)) u32 {\n    return t.find();\n}\n" },
        .{ .name = "lib", .bytes = lib, .selected = false, .package = "lib", .fingerprint = 1 },
    }, &.{.{ .from = 0, .spelling = "lib", .target = 1 }}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator(), .known = .{ .name = "lib", .fingerprint = 1 } };
    defer facts.deinit();
    const model = &project.sources[0].model;
    var load: ?Decl = null;
    var hash: ?Decl = null;
    for (model.declarations, 0..) |decl, i| {
        const id: Decl = .{ .file = project.sources[0].id, .index = @fromBackingInt(@intCast(i)) };
        if (std.mem.eql(u8, decl.name, "load")) load = id;
        if (std.mem.eql(u8, decl.name, "hash")) hash = id;
    }
    try std.testing.expect(!try facts.handedOut(load.?));
    try std.testing.expect(try facts.handedOut(hash.?));
}

test "reachedUnder: a site past a condition a binding decides is no site of that binding" {
    const source =
        \\const Plain = struct { v: u32 };
        \\const Id = enum(u32) { _ };
        \\fn value(comptime T: type, v: u32) T {
        \\    if (T == Plain) return .{ .v = v };
        \\    return @enumFromInt(v);
        \\}
        \\fn other(comptime T: type, v: u32) T {
        \\    if (T != u32 and T != Plain) {
        \\        return @enumFromInt(v);
        \\    }
        \\    return undefined;
        \\}
        \\fn kind(comptime T: type) T {
        \\    switch (@typeInfo(T)) {
        \\        .@"struct" => return undefined,
        \\        else => return @enumFromInt(0),
        \\    }
        \\}
        \\fn values(comptime T: type, a: u32, b: u32) T {
        \\    if (a == b) return undefined;
        \\    return @enumFromInt(a);
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    const model = &project.sources[0].model;
    const named = struct {
        fn decl(m: *const Model, f: Project.FileId, name: []const u8) Decl {
            for (m.declarations, 0..) |d, i| if (std.mem.eql(u8, d.name, name) and d.kind != .parameter) return .{ .file = f, .index = @fromBackingInt(@intCast(i)) };
            unreachable; // unreachable: the source declares each name asked
        }
    };
    const plain = try facts.declaration(named.decl(model, file, "Plain"));
    const id = try facts.declaration(named.decl(model, file, "Id"));
    const int: Value = .{ .primitive = "u32" };
    // Each `@enumFromInt`, in the order the functions declare them.
    var casts: std.ArrayList(Ast.Node.Index) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if ((tag == .builtin_call_two or tag == .builtin_call_two_comma) and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@enumFromInt")) try casts.append(arena.allocator(), node);
    }
    std.mem.sort(Ast.Node.Index, casts.items, tree, struct {
        fn less(t: *const Ast, a: Ast.Node.Index, b: Ast.Node.Index) bool {
            return t.nodeMainToken(a) < t.nodeMainToken(b);
        }
    }.less);
    try std.testing.expectEqual(4, casts.items.len);
    const Row = struct { function: []const u8, cast: usize, bound: Value, reached: bool };
    const unknown: Value = .{ .unknown = .unsupported };
    const rows = [_]Row{
        // `if (T == Plain) return`: past it, only another type's binding.
        .{ .function = "value", .cast = 0, .bound = plain, .reached = false },
        .{ .function = "value", .cast = 0, .bound = id, .reached = true },
        // A type the binding does not name decides nothing.
        .{ .function = "value", .cast = 0, .bound = unknown, .reached = true },
        // `and` of `!=`, with a primitive.
        .{ .function = "other", .cast = 1, .bound = int, .reached = false },
        .{ .function = "other", .cast = 1, .bound = plain, .reached = false },
        .{ .function = "other", .cast = 1, .bound = id, .reached = true },
        // The prong a switch on type information takes.
        .{ .function = "kind", .cast = 2, .bound = plain, .reached = false },
        .{ .function = "kind", .cast = 2, .bound = id, .reached = true },
        // Values compared are no types: no binding decides them.
        .{ .function = "values", .cast = 3, .bound = plain, .reached = true },
    };
    for (rows) |row| {
        // A reading is made once, where `resolveIn` may keep what it gives by its address.
        const env = try facts.gpa.create(Env);
        env.* = .{ .function = named.decl(model, file, row.function), .args = try facts.gpa.dupe(Value, &.{ row.bound, int, int }), .depth = 0 };
        try std.testing.expectEqual(row.reached, try facts.reachedUnder(env, file, casts.items[row.cast]));
    }
    // With no binding, every site is reached.
    for (casts.items) |cast| try std.testing.expect(try facts.reachedUnder(null, file, cast));
}

test "a type function is evaluated in a reading however many calls deep its chain is" {
    const source =
        \\const Foo = struct { a: u8 };
        \\fn Opt(comptime T: type) type { return ?T; }
        \\fn f0(x: anytype) void { f1(x); }
        \\fn f1(x: anytype) void { f2(x); }
        \\fn f2(x: anytype) void { f3(x); }
        \\fn f3(x: anytype) void { f4(x); }
        \\fn f4(x: anytype) void { f5(x); }
        \\fn f5(x: anytype) void { f6(x); }
        \\fn f6(x: anytype) void { f7(x); }
        \\fn f7(x: anytype) void { f8(x); }
        \\fn f8(x: anytype) void { f9(x); }
        \\fn f9(x: anytype) void {
        \\    var w: Opt(@TypeOf(x)) = undefined;
        \\    _ = &w;
        \\    _ = w.?;
        \\}
        \\pub fn main() void { f0(Foo{ .a = 1 }); }
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const root = facts.rootOf(file);
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable;
        }
    };
    var env: ?*const Env = null;
    const names = [_][]const u8{ "f0", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9" };
    for ([_][]const u8{ "f0(Foo{ .a = 1 })", "f1(x)", "f2(x)", "f3(x)", "f4(x)", "f5(x)", "f6(x)", "f7(x)", "f8(x)", "f9(x)" }, names) |text, name| {
        var buffer: [1]Ast.Node.Index = undefined;
        env = try facts.bind(file, tree.fullCall(&buffer, node.of(tree, text)).?, facts.member(root, name).?, env);
    }
    try std.testing.expectEqual(@as(usize, 9), env.?.depth);
    const value = try facts.resolveBound(env.?, file, node.of(tree, "w.?"));
    const foo = try facts.resolve(file, node.of(tree, "Foo"));
    try std.testing.expect(value == .instance and foo == .container and value.instance.scope == foo.container.scope);
}

test "a pointer's size is its type's: a reading decides a condition on it, and a pointer built of it keeps it" {
    const source =
        \\const Foo = struct { a: u8 };
        \\fn kind(p: anytype) void {
        \\    const info = @typeInfo(@TypeOf(p)).pointer;
        \\    if (info.size == .slice) {
        \\        sliceOnly(p);
        \\    } else {
        \\        oneOnly(p);
        \\    }
        \\}
        \\fn sliceOnly(p: anytype) void { _ = p; }
        \\fn oneOnly(p: anytype) void { _ = p; }
        \\fn Same(comptime P: type) type {
        \\    const info = @typeInfo(P).pointer;
        \\    return @Pointer(info.size, info.attrs, info.child, null);
        \\}
        \\pub fn main() void {
        \\    var foo: Foo = .{ .a = 1 };
        \\    var arr: [1]Foo = .{foo};
        \\    const s: []Foo = &arr;
        \\    kind(s);
        \\    kind(&foo);
        \\    const same: Same([]Foo) = s;
        \\    _ = same;
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable;
        }
    };
    const kind = facts.member(facts.rootOf(file), "kind").?;
    var buffer: [1]Ast.Node.Index = undefined;
    const by_slice = try facts.bind(file, tree.fullCall(&buffer, node.of(tree, "kind(s)")).?, kind, null);
    const by_one = try facts.bind(file, tree.fullCall(&buffer, node.of(tree, "kind(&foo)")).?, kind, null);
    const slice_only = node.of(tree, "sliceOnly(p)");
    const one_only = node.of(tree, "oneOnly(p)");
    try std.testing.expect(try facts.reachedUnder(by_slice, file, slice_only));
    try std.testing.expect(!try facts.reachedUnder(by_slice, file, one_only));
    try std.testing.expect(!try facts.reachedUnder(by_one, file, slice_only));
    try std.testing.expect(try facts.reachedUnder(by_one, file, one_only));
    // `@Pointer(info.size, ...)` makes a pointer of the size it reads.
    const built = try facts.resolve(file, node.of(tree, "Same([]Foo)"));
    try std.testing.expect(built == .pointer and built.pointer.size == .slice);
    // A pointer to one and a slice are two types.
    const one = try facts.resolve(file, node.of(tree, "&foo"));
    try std.testing.expect(one == .pointer and one.pointer.size == .one);
    try std.testing.expect(!Facts.same(one, try facts.pointerTo(one.pointer.child.*, .slice), 0));
}

test "a pointer's size read off its type information is a std.builtin.Type.Pointer.Size" {
    const root =
        \\const std = @import("std");
        \\pub fn main() void {
        \\    const size = @typeInfo([]u8).pointer.size;
        \\    _ = @as(@TypeOf(size), size);
        \\}
    ;
    const library =
        \\pub const builtin = struct {
        \\    pub const Type = struct {
        \\        pub const Pointer = struct {
        \\            pub const Size = enum { one, many, slice, c };
        \\        };
        \\    };
        \\};
    ;
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = root },
        .{ .name = "std/std.zig", .bytes = library, .selected = false },
    }, &.{.{ .from = 0, .spelling = "std", .target = 1 }}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const node = for (0..tree.nodes.len) |i| {
        const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (std.mem.eql(u8, tree.getNodeSource(at), "@TypeOf(size)")) break at;
    } else unreachable; // unreachable: the source writes it
    const size_type = try facts.resolve(file, node);
    try std.testing.expect(size_type == .container);
    const library_tree = &project.sources[1].file.tree;
    const scope = project.sources[1].model.scopes[@backingInt(size_type.container.scope)];
    try std.testing.expect(size_type.container.file == project.sources[1].id);
    try std.testing.expect(std.mem.startsWith(u8, library_tree.getNodeSource(scope.node), "enum { one, many, slice, c }"));
}

test "a call whose result type a type function builds from its argument's type reads in a reading many calls deep (std's realloc: absorbSentinel(allocation))" {
    const source =
        \\const Foo = struct { a: u8 };
        \\fn AbsorbSentinel(comptime Pointer: type) type {
        \\    const info = @typeInfo(Pointer).pointer;
        \\    switch (info.size) {
        \\        .slice => return @Pointer(.slice, info.attrs, info.child, null),
        \\        .one => {
        \\            const child_info = @typeInfo(info.child).array;
        \\            if (child_info.sentinel_ptr == null) {
        \\                return Pointer;
        \\            } else {
        \\                return @Pointer(.one, info.attrs, [child_info.len + 1]child_info.child, null);
        \\            }
        \\        },
        \\        else => unreachable,
        \\    }
        \\}
        \\fn absorbSentinel(slice: anytype) AbsorbSentinel(@TypeOf(slice)) { return slice; }
        \\fn f0(x: anytype) void { f1(x); }
        \\fn f1(x: anytype) void { f2(x); }
        \\fn f2(x: anytype) void { f3(x); }
        \\fn f3(x: anytype) void { f4(x); }
        \\fn f4(x: anytype) void { f5(x); }
        \\fn f5(x: anytype) void { f6(x); }
        \\fn f6(x: anytype) void { f7(x); }
        \\fn f7(x: anytype) void { f8(x); }
        \\fn f8(x: anytype) void { f9(x); }
        \\fn f9(allocation: anytype) void {
        \\    const old_memory = absorbSentinel(allocation);
        \\    _ = old_memory[0];
        \\}
        \\pub fn main() void {
        \\    var buffer: [4]Foo = undefined;
        \\    const items: []Foo = &buffer;
        \\    f0(items);
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const root = facts.rootOf(file);
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable;
        }
    };
    var env: ?*const Env = null;
    const names = [_][]const u8{ "f0", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9" };
    for ([_][]const u8{ "f0(items)", "f1(x)", "f2(x)", "f3(x)", "f4(x)", "f5(x)", "f6(x)", "f7(x)", "f8(x)", "f9(x)" }, names) |text, name| {
        var buffer: [1]Ast.Node.Index = undefined;
        env = try facts.bind(file, tree.fullCall(&buffer, node.of(tree, text)).?, facts.member(root, name).?, env);
    }
    try std.testing.expectEqual(@as(usize, 9), env.?.depth);
    const value = try facts.resolveBound(env.?, file, node.of(tree, "old_memory[0]"));
    const foo = try facts.resolve(file, node.of(tree, "Foo"));
    try std.testing.expect(value == .instance and foo == .container and value.instance.scope == foo.container.scope);
}

test "a generic calling itself with what its reading leaves unknown is that reading again, not one more per call" {
    const source =
        \\const lib = @import("lib");
        \\fn data(buffer: []const u32, comptime Field: type) void {
        \\    data(buffer, Field.Value);
        \\}
        \\pub fn main() void {
        \\    const buffer: []const u32 = &.{};
        \\    data(buffer, lib.Field);
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const root = facts.rootOf(file);
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable;
        }
    };
    const data = facts.member(root, "data").?;
    var buffer: [1]Ast.Node.Index = undefined;
    const first = try facts.bind(file, tree.fullCall(&buffer, node.of(tree, "data(buffer, lib.Field)")).?, data, null);
    const inner = tree.fullCall(&buffer, node.of(tree, "data(buffer, Field.Value)")).?;
    const second = try facts.bind(file, inner, data, first);
    try std.testing.expect(second.args[1] == .unknown);
    const third = try facts.bind(file, inner, data, second);
    try std.testing.expect(third == second);
}

test "a type function's call written at two sites makes one type: a generic given either is read once" {
    const source =
        \\const Foo = struct { a: u8 };
        \\const Bar = struct { b: u16 };
        \\fn Box(comptime T: type) type { return struct { value: T }; }
        \\fn use(box: anytype) void { _ = box.value; }
        \\pub fn main() void {
        \\    const x: Box(Foo) = undefined;
        \\    const y: Box(Foo) = undefined;
        \\    const z: Box(Bar) = undefined;
        \\    use(x);
        \\    use(y);
        \\    use(z);
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const root = facts.rootOf(file);
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable;
        }
    };
    var readings: [3]*const Env = undefined;
    for ([_][]const u8{ "use(x)", "use(y)", "use(z)" }, &readings) |text, *reading| {
        var buffer: [1]Ast.Node.Index = undefined;
        reading.* = try facts.bind(file, tree.fullCall(&buffer, node.of(tree, text)).?, facts.member(root, "use").?, null);
    }
    try std.testing.expect(readings[0].args[0] == .instance);
    try std.testing.expect(readings[0] == readings[1]);
    try std.testing.expect(readings[0] != readings[2]);
}

test "@This() in a made container's method is the container its reading made: its fields read that reading's bindings" {
    const source =
        \\const Foo = struct { a: u8 };
        \\fn List(comptime Elem: type) type {
        \\    return struct {
        \\        items: []const Elem,
        \\        fn first(list: @This()) Elem {
        \\            return list.items[0];
        \\        }
        \\    };
        \\}
        \\pub fn main() void {
        \\    const foos: []const Foo = &.{};
        \\    const list: List(Foo) = .{ .items = foos };
        \\    _ = list.first();
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable;
        }
    };
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node.of(tree, "list.first()")).?;
    const first = switch (try facts.definition(file, call.ast.fn_expr)) {
        .decl => |decl| decl,
        .none, .unknown => unreachable, // unreachable: the call names the method
    };
    const env = try facts.bind(file, call, first, null);
    const this = try facts.resolveBound(env, file, node.of(tree, "@This()"));
    try std.testing.expect(this == .container and this.container.made_by != null);
    const value = try facts.resolveBound(env, file, node.of(tree, "list.items[0]"));
    const foo = try facts.resolve(file, node.of(tree, "Foo"));
    try std.testing.expect(value == .instance and foo == .container and value.instance.scope == foo.container.scope);
}

test "a container a generic declares in its body is its reading's: its fields read that reading's bindings" {
    const source =
        \\const Foo = struct { a: u8 };
        \\const Bar = struct { b: u16 };
        \\fn spawn(args: anytype) void {
        \\    const Args = @TypeOf(args);
        \\    const Instance = struct { fn_args: Args };
        \\    var instance: Instance = undefined;
        \\    _ = &instance;
        \\    _ = instance.fn_args;
        \\}
        \\pub fn main() void {
        \\    spawn(Foo{ .a = 1 });
        \\    spawn(Bar{ .b = 2 });
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const root = facts.rootOf(file);
    const spawn = facts.member(root, "spawn").?;
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable;
        }
    };
    const field = node.of(tree, "instance.fn_args");
    for ([_]struct { []const u8, []const u8 }{ .{ "spawn(Foo{ .a = 1 })", "Foo" }, .{ "spawn(Bar{ .b = 2 })", "Bar" } }) |row| {
        const call_text, const type_name = row;
        var buffer: [1]Ast.Node.Index = undefined;
        const env = try facts.bind(file, tree.fullCall(&buffer, node.of(tree, call_text)).?, spawn, null);
        const value = try facts.resolveBound(env, file, field);
        try std.testing.expect(value == .instance);
        const expected = try facts.resolve(file, node.of(tree, type_name));
        try std.testing.expect(expected == .container and value.instance.scope == expected.container.scope);
    }
}

test "reachedUnder: a binding decides a type's kind, whether a struct is a tuple, and a primitive's kind" {
    const source =
        \\const Plain = struct { v: u32 };
        \\const Pair = struct { u8, u16 };
        \\const Id = enum(u32) { _ };
        \\fn kinds(comptime T: type) T {
        \\    if (@typeInfo(T) == .@"struct") return undefined;
        \\    return @enumFromInt(0);
        \\}
        \\fn tuples(comptime T: type) T {
        \\    if (@typeInfo(T).@"struct".is_tuple) return undefined;
        \\    return @enumFromInt(0);
        \\}
        \\fn ints(comptime T: type) T {
        \\    if (@typeInfo(T) != .int) return undefined;
        \\    return @enumFromInt(0);
        \\}
        \\fn prongs(comptime T: type) T {
        \\    switch (@typeInfo(T)) {
        \\        .int, .comptime_int => return undefined,
        \\        else => return @enumFromInt(0),
        \\    }
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    const model = &project.sources[0].model;
    const named = struct {
        fn decl(m: *const Model, f: Project.FileId, name: []const u8) Decl {
            for (m.declarations, 0..) |d, i| if (std.mem.eql(u8, d.name, name) and d.kind != .parameter) return .{ .file = f, .index = @fromBackingInt(@intCast(i)) };
            unreachable; // unreachable: the source declares each name asked
        }
    };
    const plain = try facts.declaration(named.decl(model, file, "Plain"));
    const pair = try facts.declaration(named.decl(model, file, "Pair"));
    const id = try facts.declaration(named.decl(model, file, "Id"));
    const int: Value = .{ .primitive = "u32" };
    const float: Value = .{ .primitive = "f32" };
    // Each `@enumFromInt`, in the order the functions declare them.
    var casts: std.ArrayList(Ast.Node.Index) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if ((tag == .builtin_call_two or tag == .builtin_call_two_comma) and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@enumFromInt")) try casts.append(arena.allocator(), node);
    }
    std.mem.sort(Ast.Node.Index, casts.items, tree, struct {
        fn less(t: *const Ast, a: Ast.Node.Index, b: Ast.Node.Index) bool {
            return t.nodeMainToken(a) < t.nodeMainToken(b);
        }
    }.less);
    try std.testing.expectEqual(4, casts.items.len);
    const Row = struct { function: []const u8, cast: usize, bound: Value, reached: bool };
    const rows = [_]Row{
        // `@typeInfo(T) == .tag` (kindCompared): a struct returns before it, an enum gets past.
        .{ .function = "kinds", .cast = 0, .bound = plain, .reached = false },
        .{ .function = "kinds", .cast = 0, .bound = id, .reached = true },
        // `is_tuple` (isTuple): a struct of unnamed fields is one, a struct of named ones is not.
        .{ .function = "tuples", .cast = 1, .bound = pair, .reached = false },
        .{ .function = "tuples", .cast = 1, .bound = plain, .reached = true },
        // A primitive's kind (primitiveKind): `u32` is an int, `f32` a float.
        .{ .function = "ints", .cast = 2, .bound = int, .reached = true },
        .{ .function = "ints", .cast = 2, .bound = float, .reached = false },
        .{ .function = "ints", .cast = 2, .bound = plain, .reached = false },
        .{ .function = "prongs", .cast = 3, .bound = int, .reached = false },
        .{ .function = "prongs", .cast = 3, .bound = float, .reached = true },
    };
    for (rows) |row| {
        const env = try arena.allocator().create(Env);
        env.* = .{ .function = named.decl(model, file, row.function), .args = &.{row.bound}, .depth = 0 };
        try std.testing.expectEqual(row.reached, try facts.reachedUnder(env, file, casts.items[row.cast]));
    }
}

test "reachedUnder: a bool function's body decides by the branch a switch or an if takes, both ways of a condition it does not settle where they agree, and however deep the caller's reading is" {
    const source =
        \\fn kind(comptime T: type) ?u8 {
        \\    _ = T;
        \\    return null;
        \\}
        \\fn scalar(comptime T: type) bool {
        \\    return switch (@typeInfo(T)) {
        \\        .int => true,
        \\        else => false,
        \\    };
        \\}
        \\fn guarded(comptime T: type) bool {
        \\    if (kind(T) != null) return true;
        \\    return @typeInfo(T) == .int;
        \\}
        \\fn asking(comptime T: type) bool {
        \\    if (kind(T) != null) return asking(T);
        \\    return false;
        \\}
        \\fn bySwitch(comptime T: type) T {
        \\    if (comptime scalar(T)) return undefined;
        \\    return @enumFromInt(0);
        \\}
        \\fn byBoth(comptime T: type) T {
        \\    if (comptime guarded(T)) return undefined;
        \\    return @enumFromInt(0);
        \\}
        \\fn byItself(comptime T: type) T {
        \\    if (comptime asking(T)) return undefined;
        \\    return @enumFromInt(0);
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    const model = &project.sources[0].model;
    const named = struct {
        fn decl(m: *const Model, f: Project.FileId, name: []const u8) Decl {
            for (m.declarations, 0..) |d, i| if (std.mem.eql(u8, d.name, name) and d.kind != .parameter) return .{ .file = f, .index = @fromBackingInt(@intCast(i)) };
            unreachable; // unreachable: the source declares each name asked
        }
    };
    const int: Value = .{ .primitive = "u32" };
    const float: Value = .{ .primitive = "f32" };
    // Each `@enumFromInt`, in the order the functions declare them.
    var casts: std.ArrayList(Ast.Node.Index) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if ((tag == .builtin_call_two or tag == .builtin_call_two_comma) and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@enumFromInt")) try casts.append(arena.allocator(), node);
    }
    std.mem.sort(Ast.Node.Index, casts.items, tree, struct {
        fn less(t: *const Ast, a: Ast.Node.Index, b: Ast.Node.Index) bool {
            return t.nodeMainToken(a) < t.nodeMainToken(b);
        }
    }.less);
    try std.testing.expectEqual(3, casts.items.len);
    const Row = struct { function: []const u8, cast: usize, bound: Value, depth: usize = 0, reached: bool };
    const rows = [_]Row{
        // `return switch (@typeInfo(T))`: the prong the binding takes gives the value.
        .{ .function = "bySwitch", .cast = 0, .bound = int, .reached = false },
        .{ .function = "bySwitch", .cast = 0, .bound = float, .reached = true },
        // `kind(T) != null` is not settled; both ways return true for an int, and they differ
        // for a float (true, or false past it): undecided, so reached.
        .{ .function = "byBoth", .cast = 1, .bound = int, .reached = false },
        .{ .function = "byBoth", .cast = 1, .bound = float, .reached = true },
        // A caller's reading deep in a chain of calls decides it all the same.
        .{ .function = "byBoth", .cast = 1, .bound = int, .depth = 12, .reached = false },
        // `asking(T)` asks itself on the same reading: not known by its own reading.
        .{ .function = "byItself", .cast = 2, .bound = int, .reached = true },
    };
    for (rows) |row| {
        const env = try arena.allocator().create(Env);
        env.* = .{ .function = named.decl(model, file, row.function), .args = &.{row.bound}, .depth = row.depth };
        try std.testing.expectEqual(row.reached, try facts.reachedUnder(env, file, casts.items[row.cast]));
    }
}

test "the walk decides a bool function's call by its body in the call's reading, and reads a generic once per type an argument may be" {
    const source =
        \\inline fn hasFn(comptime T: type, comptime name: []const u8) bool {
        \\    switch (@typeInfo(T)) {
        \\        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        \\        else => return false,
        \\    }
        \\    if (!@hasDecl(T, name)) return false;
        \\    return @typeInfo(@TypeOf(@field(T, name))) == .@"fn";
        \\}
        \\const Parsed = struct {
        \\    pub fn jsonParse() void {}
        \\};
        \\const Plain = struct { v: u32 };
        \\fn parsed(comptime T: type) void {
        \\    _ = T;
        \\}
        \\fn plain(comptime T: type) void {
        \\    _ = T;
        \\}
        \\fn parse(comptime T: type) void {
        \\    if (hasFn(T, "jsonParse")) parsed(T) else plain(T);
        \\}
        \\fn either(comptime T: type) void {
        \\    if (hasFn(T, "jsonParse")) parsedEither(T) else plainEither(T);
        \\}
        \\fn parsedEither(comptime T: type) void {
        \\    _ = T;
        \\}
        \\fn plainEither(comptime T: type) void {
        \\    _ = T;
        \\}
        \\fn pick(n: u8) bool {
        \\    return n > 3;
        \\}
        \\pub fn main() void {
        \\    parse(Parsed);
        \\    either(if (pick(5)) Parsed else Plain);
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const model = &project.sources[0].model;
    const named = struct {
        fn decl(m: *const Model, f: Project.FileId, name: []const u8) Decl {
            for (m.declarations, 0..) |d, i| if (std.mem.eql(u8, d.name, name) and d.kind != .parameter) return .{ .file = f, .index = @fromBackingInt(@intCast(i)) };
            unreachable; // unreachable: the source declares each name asked
        }
    };
    const found = try facts.analysis();
    try std.testing.expect(!found.everything);
    try std.testing.expectEqual(0, found.limits.items.len);
    // A generic is read only in the instantiations calls make (a non-generic function of the
    // program is read on its own).
    // `hasFn(Parsed, "jsonParse")` is true in parse's one reading (callTruth): `plain` is never called.
    try std.testing.expect(try facts.analyzed(named.decl(model, file, "parsed")));
    try std.testing.expect(!try facts.analyzed(named.decl(model, file, "plain")));
    // An argument that is one of two types is read as each (reachEach): both branches are taken,
    // each in its own reading. (`pick(5)`'s `n > 3` is not decided; a `pick` whose body returns
    // `true` would be, and `either` read with `Parsed` alone.)
    try std.testing.expect(try facts.analyzed(named.decl(model, file, "parsedEither")));
    try std.testing.expect(try facts.analyzed(named.decl(model, file, "plainEither")));
    const readings = (try facts.analyzedReadings(named.decl(model, file, "either"))) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(2, readings.len);
}

test "an anytype handed a value reads as one (Env.values): an uncalled @field of it names a field; handed a type, it may name a declaration; a called one may be its type's method" {
    const library =
        \\const missing = @import("missing");
        \\pub const Other = struct {
        \\    pub fn stay() void {}
        \\    pub fn go() void {}
        \\    pub fn ops() void {}
        \\};
        \\fn which() []const u8 {
        \\    return "stay";
        \\}
        \\fn read(container: anytype) void {
        \\    _ = @field(container, which());
        \\    _ = @field(container, "stay");
        \\}
        \\pub fn data(comptime T: type, result: T) void {
        \\    read(result);
        \\}
        \\pub fn readType(x: anytype) void {
        \\    _ = @field(x, "go");
        \\}
        \\const Ops = struct { ops: u32 };
        \\pub const Impl = struct {
        \\    pub fn ops(self: *Impl) void {
        \\        _ = self;
        \\    }
        \\};
        \\pub fn each(impl: *Impl) void {
        \\    inline for (@typeInfo(Ops).@"struct".field_names) |name| @field(impl, name)();
        \\}
        \\pub fn take(x: anytype) void {
        \\    _ = x;
        \\}
    ;
    const source =
        \\const lib = @import("std");
        \\const missing = @import("missing");
        \\pub fn main() void {
        \\    lib.data(missing.T, undefined);
        \\    lib.readType(missing.T);
        \\    var impl: lib.Impl = .{};
        \\    lib.each(&impl);
        \\    const s: u8 = 0;
        \\    lib.take(u8);
        \\    lib.take(s);
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = source },
        .{ .name = "std/std.zig", .bytes = library, .selected = false },
    }, &.{.{ .from = 0, .spelling = "std", .target = 1 }}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[1].id;
    const model = &project.sources[1].model;
    const named = struct {
        fn decl(m: *const Model, f: Project.FileId, name: []const u8, nth: usize) Decl {
            var left = nth;
            for (m.declarations, 0..) |d, i| if (std.mem.eql(u8, d.name, name) and d.kind == .function) {
                if (left == 0) return .{ .file = f, .index = @fromBackingInt(@intCast(i)) };
                left -= 1;
            };
            unreachable; // unreachable: the source declares each name asked
        }
    };
    const found = try facts.analysis();
    // `read(result)`: `container` is handed a value, so `@field(container, which())` names a
    // field of it, whatever its type: no declaration, and the walk does not give up.
    try std.testing.expect(!found.everything);
    try std.testing.expectEqual(0, found.limits.items.len);
    try std.testing.expect(!try facts.analyzed(named.decl(model, file, "stay", 0)));
    // `readType(missing.T)`: handed what may be a type, `@field(x, "go")` may be its
    // declaration: every `go` is reached.
    try std.testing.expect(try facts.analyzed(named.decl(model, file, "go", 0)));
    // `@field(impl, name)()` through a value: the method of its type so named, not another's.
    try std.testing.expect(try facts.analyzed(named.decl(model, file, "ops", 1)));
    try std.testing.expect(!try facts.analyzed(named.decl(model, file, "ops", 0)));
    // `take(u8)` and `take(s)`: a type and a value are two instantiations.
    const readings = (try facts.analyzedReadings(named.decl(model, file, "take", 0))).?;
    try std.testing.expectEqual(2, readings.len);
}

test "a call on what a generic's context binds resolves in the instantiation its chain of calls makes" {
    const source =
        \\pub fn AutoContext(comptime K: type) type {
        \\    return struct { pub const hash = getAutoHashFn(K, @This()); };
        \\}
        \\fn getAutoHashFn(comptime K: type, comptime Context: type) (fn (Context, K) u64) {
        \\    return struct { fn hash(ctx: Context, key: K) u64 { _ = ctx; _ = key; return 0; } }.hash;
        \\}
        \\pub fn HashMapUnmanaged(comptime K: type, comptime V: type, comptime Context: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        size: u32 = 0,
        \\        pub fn getContext(self: Self, key: K, ctx: Context) ?V { return self.getAdapted(key, ctx); }
        \\        pub fn getAdapted(self: Self, key: anytype, ctx: anytype) ?V { _ = self.getIndex(key, ctx); return null; }
        \\        fn getIndex(self: Self, key: anytype, ctx: anytype) ?usize { _ = self; _ = ctx.hash(key); return null; }
        \\    };
        \\}
        \\pub fn HashMap(comptime K: type, comptime V: type, comptime Context: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        pub const Unmanaged = HashMapUnmanaged(K, V, Context);
        \\        unmanaged: Unmanaged,
        \\        ctx: Context,
        \\        pub fn get(self: Self, key: K) ?V { return self.unmanaged.getContext(key, self.ctx); }
        \\    };
        \\}
        \\pub fn AutoHashMap(comptime K: type, comptime V: type) type { return HashMap(K, V, AutoContext(K)); }
        \\const M = AutoHashMap(u32, u8);
        \\pub fn f(m: M, k: u32) ?u8 { return m.get(k); }
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const named = struct {
        /// The call whose callee is spelled ending in `name`.
        fn call(t: *const Ast, name: []const u8) Ast.Node.Index {
            for (t.nodes.items(.tag), 0..) |_, i| {
                const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                var buffer: [1]Ast.Node.Index = undefined;
                const full = t.fullCall(&buffer, node) orelse continue;
                if (std.mem.eql(u8, t.tokenSlice(t.lastToken(full.ast.fn_expr)), name)) return node;
            }
            unreachable;
        }
    };
    var env: ?*const Env = null;
    for ([_][]const u8{ "get", "getContext", "getAdapted", "getIndex" }) |name| {
        const node = named.call(tree, name);
        const found = (try calls.under(&facts, env, file, node)).?;
        try std.testing.expect(found.callee == .function);
        var buffer: [1]Ast.Node.Index = undefined;
        env = try facts.bind(file, tree.fullCall(&buffer, node).?, found.callee.function, env);
    }
    const hash = named.call(tree, "hash");
    const bound = (try calls.under(&facts, env, file, hash)).?;
    try std.testing.expect(bound.callee == .function);
    try std.testing.expectEqualStrings("hash", project.sources[0].model.declarations[@backingInt(bound.callee.function.index)].name);
    try std.testing.expect(bound.receiver == .bound);
    // Read in no instantiation, the context is each binding's: what it calls is not known.
    try std.testing.expect((try calls.at(&facts, file, hash)).?.callee == .any);
}

test "a method of a value a type parameter types is made per binding: each binding reads what the call makes with its arguments" {
    const source =
        \\pub const Probed = union(enum) { is, none };
        \\pub const Facts = struct {
        \\    hits: u32 = 0,
        \\    pub fn fieldsHold(self: *Facts, comptime Probe: type, probe: Probe, n: u32) (error{Bad} || Probe.Error)!Probed {
        \\        return self.fieldsHoldOnce(Probe, probe, n);
        \\    }
        \\    fn fieldsHoldOnce(self: *Facts, comptime Probe: type, probe: Probe, n: u32) (error{Bad} || Probe.Error)!Probed {
        \\        switch (try probe.of(self, n)) {
        \\            .is => return .is,
        \\            .none => return .none,
        \\        }
        \\    }
        \\};
        \\const IoProbe = struct {
        \\    key: u32,
        \\    pub const Error = error{};
        \\    pub fn of(probe: IoProbe, facts: *Facts, n: u32) Error!Probed {
        \\        _ = facts;
        \\        return if (probe.key == n) .is else .none;
        \\    }
        \\};
        \\pub fn main() !void {
        \\    var facts: Facts = .{};
        \\    _ = try facts.fieldsHold(IoProbe, .{ .key = 1 }, 3);
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable;
        }
    };
    const made = node.of(tree, "probe.of(self, n)");
    // The generic's own call is its binding's: a made copy of `fieldsHold`, through its call of
    // `fieldsHoldOnce`, its source the call.
    const hold = switch (try facts.definition(file, node.of(tree, "facts.fieldsHold"))) {
        .decl => |decl| decl,
        .none, .unknown => unreachable, // unreachable: the call names the method
    };
    try std.testing.expect(facts.madeByParameter(file, made) != null);
    const copies = try facts.parameterCopies(hold);
    var found: ?ParameterCopy = null;
    for (copies) |copy| if (copy.kind == .made and copy.source != null and copy.source.?.node == made) {
        found = copy;
    };
    try std.testing.expect(found != null);
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node.of(tree, "facts.fieldsHold(IoProbe, .{ .key = 1 }, 3)")).?;
    const env = try facts.bind(file, call, hold, null);
    var inner_buffer: [1]Ast.Node.Index = undefined;
    const inner = tree.fullCall(&inner_buffer, node.of(tree, "self.fieldsHoldOnce(Probe, probe, n)")).?;
    const once = switch (try facts.definition(file, inner.ast.fn_expr)) {
        .decl => |decl| decl,
        .none, .unknown => unreachable, // unreachable: the call names the method
    };
    const env2 = try facts.bind(file, inner, once, env);
    // In that reading the literal is the probe its parameter's type names, so its method is
    // that type's.
    const access = node.of(tree, "probe.of");
    try std.testing.expect(try facts.resolveBound(env2, file, tree.nodeData(access).node_and_token[0]) == .instance);
    try std.testing.expect(try facts.resolveBound(env2, file, access) == .function);
    const binding = (try calls.at(&facts, file, node.of(tree, "facts.fieldsHold(IoProbe, .{ .key = 1 }, 3)"))).?;
    const value = (try facts.boundCopy(binding, hold, found.?)).?;
    try std.testing.expect(value == .error_union and value.error_union.* == .instance);
}

/// What `facts` reads for `io.vtable.run` in the library of `storeWalk`'s project, past
/// pointers: a function, a choice of them, or anything else.
fn storeWalk(root: []const u8, library_tail: []const u8) !struct { futex: bool, real: bool, other: bool, call: FieldRead, everything: bool } {
    const library_head =
        \\pub const VTable = struct { run: *const fn () void };
        \\pub const Io = struct {
        \\    vtable: *const VTable,
        \\    pub fn run(io: Io) void {
        \\        io.vtable.run();
        \\    }
        \\};
        \\pub fn real() void {
        \\    reached();
        \\}
        \\pub const real_vtable: VTable = .{ .run = real };
        \\pub const Unreached = struct {
        \\    fn futex() void {}
        \\    pub const vt: VTable = .{ .run = futex };
        \\};
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = root },
        .{ .name = "std/std.zig", .bytes = try std.mem.concat(a, u8, &.{ library_head, library_tail }), .selected = false },
    }, &.{.{ .from = 0, .spelling = "std", .target = 1 }}, .{});
    defer project.deinit();
    var facts: Facts = .{ .project = &project, .gpa = a };
    defer facts.deinit();
    const file = project.sources[1].id;
    const model = &project.sources[1].model;
    const tree = &project.sources[1].file.tree;
    const function = struct {
        fn decl(m: *const Model, f: Project.FileId, name: []const u8) Decl {
            for (m.declarations, 0..) |d, i| if (std.mem.eql(u8, d.name, name) and d.kind == .function) return .{ .file = f, .index = @fromBackingInt(@intCast(i)) };
            unreachable; // unreachable: the library declares each name asked
        }
    };
    const found = try facts.analysis();
    const call = for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) == .field_access and std.mem.eql(u8, tree.getNodeSource(node), "io.vtable.run")) break node;
    } else unreachable; // unreachable: Io.run calls through it
    var value = try facts.resolve(file, call);
    while (value == .pointer) value = value.pointer.child.*;
    return .{
        .futex = try facts.analyzed(function.decl(model, file, "futex")),
        .real = try facts.analyzed(function.decl(model, file, "real")),
        // A function the tail declares and stores, where it does.
        .other = for (model.declarations, 0..) |d, i| {
            if (std.mem.eql(u8, d.name, "other") and d.kind == .function) break try facts.analyzed(.{ .file = file, .index = @fromBackingInt(@intCast(i)) });
        } else false,
        .call = switch (value) {
            .function => .function,
            .alternatives => .choice,
            else => .any,
        },
        .everything = found.everything,
    };
}

test "a store counts for a call through its field once the walk reaches its part: one in code nothing compiles gives nothing, even a store that would leave the call unresolved" {
    const through_io = "const std = @import(\"std\");\npub fn main() void {\n    const io: std.Io = .{ .vtable = &std.real_vtable };\n    io.run();\n}\n";
    // The store of `futex` is in a declaration nothing reaches (aegis's test-only shake layer):
    // the call reaches `real` alone.
    const plain = "fn reached() void {}\n";
    const alone = try storeWalk(through_io, plain);
    try std.testing.expect(!alone.everything);
    try std.testing.expect(alone.real and !alone.futex);
    try std.testing.expectEqual(.function, alone.call);
    // Its twin reaches that declaration: the call reaches both.
    const reached = try storeWalk("const std = @import(\"std\");\npub fn main() void {\n    const io: std.Io = .{ .vtable = &std.real_vtable };\n    io.run();\n    _ = std.Unreached.vt;\n}\n", plain);
    try std.testing.expect(reached.real and reached.futex);
    try std.testing.expectEqual(.choice, reached.call);
    // A store nothing reaches that takes the field's address leaves the call resolved.
    const hidden = try storeWalk(through_io, plain ++ "const Hidden = struct {\n    fn take(v: *VTable) void {\n        _ = &v.run;\n    }\n};\n");
    try std.testing.expectEqual(.function, hidden.call);
    // Its order twin: the call is read first; `real`, which it reaches, reaches `later`, whose
    // part takes the field's address and stores `other`, named nowhere else. Reading the call
    // again leaves it unresolved, and the walk reaches `other` by its name at the store, not
    // by the call's answer: no part of the walk waits on a call through a field, nor gives up.
    const late = try storeWalk(through_io, "fn reached() void {\n    var vt: VTable = real_vtable;\n    later(&vt);\n}\nfn other() void {}\nfn later(v: *VTable) void {\n    _ = &v.run;\n    v.run = other;\n}\n");
    try std.testing.expect(late.real and late.other);
    try std.testing.expect(!late.everything);
    try std.testing.expectEqual(.any, late.call);
}

test "a node's part is read off the file's index, as the parent walk finds it: every node of a file, another file's index made between" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "Facts.zig", .bytes = @embedFile("Facts.zig") },
        .{ .name = "small.zig", .bytes = "const S = struct {\n    x: u32 = 0,\n    fn f() void {}\n};\ncomptime {\n    _ = S;\n}\ntest \"t\" {}\n" },
    }, &.{}, .{});
    defer project.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const big = project.sources[0].id;
    const small = project.sources[1].id;
    const held = try facts.partsOf(big);
    for (0..project.sources[1].file.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        try std.testing.expectEqual(facts.partWalk(small, node), try facts.partOf(small, node));
    }
    try std.testing.expect(held == try facts.partsOf(big));
    for (0..project.sources[0].file.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        try std.testing.expectEqual(facts.partWalk(big, node), try facts.partOf(big, node));
    }
}

test "a memo the walk was handed is replaced once the analysis is built, one it never asked for kept" {
    const root = "const std = @import(\"std\");\npub fn main() void {\n    const io: std.Io = .{ .vtable = &std.real_vtable };\n    io.run();\n}\n";
    const library =
        \\pub const VTable = struct { run: *const fn () void };
        \\pub const Io = struct {
        \\    vtable: *const VTable,
        \\    pub fn run(io: Io) void {
        \\        io.vtable.run();
        \\    }
        \\};
        \\fn real() void {}
        \\pub const real_vtable: VTable = .{ .run = real };
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = root },
        .{ .name = "std/std.zig", .bytes = library, .selected = false },
    }, &.{.{ .from = 0, .spelling = "std", .target = 1 }}, .{});
    defer project.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    // Both made before the walk: the call through `io.vtable.run` reads `run`'s write sites
    // (accesses' index) while the walk builds; nothing asks for `Untouched`.
    const Untouched = struct { n: u32 = 0 };
    const untouched = try facts.memo(Untouched);
    untouched.n = 7;
    const index = try facts.memo(accesses.State);
    const found = try facts.analysis();
    try std.testing.expect(!found.everything);
    try std.testing.expect(try facts.memo(accesses.State) != index);
    try std.testing.expect(try facts.memo(Untouched) == untouched and untouched.n == 7);
    try std.testing.expect(try facts.analysis() == found);
}

test "a condition read inside a cycle is not kept: asked again once the cycle closes, on its reading or another, it is decided" {
    const source =
        \\const Plain = struct {};
        \\const T = Plain;
        \\fn g(comptime X: type) void {
        \\    _ = X;
        \\    if (T == Plain) {}
        \\}
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root.zig", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable; // unreachable: the source holds each text asked
        }
    };
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    const model = &project.sources[0].model;
    const condition = node.of(tree, "T == Plain");
    const named = tree.nodeData(condition).node_and_node[0];
    // `T` is being read: the condition asked meanwhile meets the cycle and is not decided.
    const reading: Settled = .{ .key = .{ .file = file, .node = named }, .assumed = facts.assumed };
    try facts.active.put(facts.gpa, reading, {});
    try std.testing.expectEqual(@as(?bool, null), try facts.comptimeTruth(null, file, condition));
    _ = facts.active.remove(reading);
    // That unknown was provisional, not kept: asked again once the cycle closes, it is decided.
    try std.testing.expectEqual(@as(?bool, true), try facts.comptimeTruth(null, file, condition));
    // As another reading of `g` decides it.
    const g = for (model.declarations, 0..) |d, i| {
        if (d.kind == .function and std.mem.eql(u8, d.name, "g")) break Decl{ .file = file, .index = @fromBackingInt(@intCast(i)) };
    } else unreachable; // unreachable: the source declares g
    const argument = try facts.resolve(file, node.of(tree, "Plain"));
    const env = try facts.keptReading(.{ .function = g, .args = &.{argument}, .depth = 0, .values = &.{false} });
    try std.testing.expectEqual(@as(?bool, true), try facts.comptimeTruth(env, file, condition));
}

test "a @field name of the holder's own fields or tags names no declaration, for a type parameter, its value, @TypeOf and a container" {
    const source =
        \\const S = struct { a: u8, b: u8 };
        \\const T = struct { a: u8 };
        \\const E = enum { a, b };
        \\pub fn same(comptime X: type, value: X) void {
        \\    switch (@typeInfo(X)) {
        \\        .@"struct" => |s| inline for (s.field_names, 0..) |name, i| { _ = i; _ = @field(value, name); },
        \\        else => {},
        \\    }
        \\}
        \\pub fn other(comptime X: type, comptime Y: type) void {
        \\    inline for (@typeInfo(X).@"struct".field_names) |name| _ = @field(Y, name);
        \\}
        \\pub fn concrete(s: S, t: T) void {
        \\    inline for (@typeInfo(S).@"struct".field_names) |name| _ = @field(s, name);
        \\    inline for (@typeInfo(S).@"struct".field_names) |name| _ = @field(t, name);
        \\}
        \\pub fn tags(comptime e: E, v: anytype) void {
        \\    _ = @field(E, @tagName(e));
        \\    _ = @field(v, @typeInfo(@TypeOf(v)).@"struct".field_names[0]);
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    var found: std.ArrayList(bool) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .builtin_call_two) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field")) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = builtinArgs(tree, node, &buffer);
        try found.append(arena.allocator(), try facts.fieldNameOwn(project.sources[0].id, args[0], args[1]));
    }
    try std.testing.expectEqualSlices(bool, &.{ true, false, true, false, true, true }, found.items);
}

test "an array of types a block fills through a loop's pointer captures is what each capture is given (std's Io.Operation.Result)" {
    const head =
        \\const A = struct {
        \\    pub const Result = u32;
        \\};
        \\const B = struct {
        \\    pub const Result = bool;
        \\};
        \\const Operation = union(enum) { a: A, b: B };
        \\const Tag = @typeInfo(Operation).@"union".tag_type.?;
        \\pub const Result = Result: {
        \\    const operation_info = @typeInfo(Operation).@"union";
        \\    const operation_count = operation_info.field_names.len;
        \\    var field_names: [operation_count][]const u8 = undefined;
        \\    var field_types: [operation_count]type = undefined;
        \\    for (operation_info.field_names, operation_info.field_types, &field_names, &field_types) |f_name, f_type, *field_name, *field_type| {
        \\        field_name.* = f_name;
        \\        field_type.* = if (f_type == noreturn) noreturn else f_type.Result;
        \\
    ;
    const tail =
        \\    }
        \\    break :Result @Union(.auto, Tag, &field_names, &field_types, &@splat(.{}));
        \\};
    ;
    for ([_]struct { []const u8, bool }{
        // Each element written through the capture: the union's fields are its operations' results.
        .{ head ++ tail, true },
        // The capture kept as well: a write through it unseen, the array unknown.
        .{ head ++ "        const kept = field_type;\n        _ = kept;\n" ++ tail, false },
    }) |row| {
        const source, const known = row;
        var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
        defer project.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
        defer facts.deinit();
        const tree = &project.sources[0].file.tree;
        const file = project.sources[0].id;
        const built = for (0..tree.nodes.len) |i| {
            const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (std.mem.startsWith(u8, tree.getNodeSource(at), "@Union(")) break at;
        } else unreachable; // unreachable: each source builds the union
        const value = try facts.resolve(file, built);
        try std.testing.expectEqual(known, value == .reified);
        if (!known) continue;
        // What its fields may hold: each operation's result, or `noreturn`.
        const fields = value.reified.fields.*;
        try std.testing.expect(fields == .alternatives);
        for (fields.alternatives) |one| try std.testing.expect(one == .primitive);
    }
}

test "a generic's copy is read in a binding only along the routes it compiles, and an unresolved copy as a value of its place's type" {
    const source =
        \\fn dup(comptime T: type, v: T) T {
        \\    return T.clone(v);
        \\}
        \\fn keep(comptime T: type, v: T) T {
        \\    switch (@typeInfo(T)) {
        \\        .@"union" => return dup(T, v),
        \\        else => return v,
        \\    }
        \\}
        \\fn made(comptime T: type, v: T, r: anytype) T {
        \\    _ = v;
        \\    return r.unknown();
        \\}
        \\pub fn main() void {
        \\    _ = keep(bool, true);
        \\    _ = made(bool, true, 0);
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable; // unreachable: the source holds each text asked
        }
    };
    const routed = struct {
        fn copyAt(f: *Facts, function: Decl, at: Ast.Node.Index) !ParameterCopy {
            for (try f.parameterCopies(function)) |copy| if (copy.source != null and copy.source.?.node == at) return copy;
            return error.TestUnexpectedResult;
        }
    };
    const binding = (try calls.at(&facts, file, node.of(tree, "keep(bool, true)"))).?;
    const keep = binding.callee.function;
    // The route through `dup` is the union's prong: a bool's instantiation compiles none of it.
    const through_dup = try routed.copyAt(&facts, keep, node.of(tree, "T.clone(v)"));
    try std.testing.expectEqual(1, through_dup.path.len);
    try std.testing.expectEqual(@as(?Value, null), try facts.boundCopy(binding, keep, through_dup));
    // `r.unknown()` does not resolve; `made` returns it as its `T`, a bool in this binding.
    const made_call = (try calls.at(&facts, file, node.of(tree, "made(bool, true, 0)"))).?;
    const made_fn = made_call.callee.function;
    const unresolved = try routed.copyAt(&facts, made_fn, node.of(tree, "r.unknown()"));
    const value = (try facts.boundCopy(made_call, made_fn, unresolved)).?;
    try std.testing.expect(value != .unknown);
}

test "a crowded copy is read along a route of generics deeper than any count of calls, by the steps its walk reads" {
    const source =
        \\fn dup(comptime T: type, v: T) T {
        \\    return T.clone(v);
        \\}
        \\fn p0(comptime T: type, v: T) T {
        \\    return p1(T, v);
        \\}
        \\fn p1(comptime T: type, v: T) T {
        \\    return p2(T, v);
        \\}
        \\fn p2(comptime T: type, v: T) T {
        \\    return p3(T, v);
        \\}
        \\fn p3(comptime T: type, v: T) T {
        \\    return p4(T, v);
        \\}
        \\fn p4(comptime T: type, v: T) T {
        \\    return p5(T, v);
        \\}
        \\fn p5(comptime T: type, v: T) T {
        \\    return p6(T, v);
        \\}
        \\fn p6(comptime T: type, v: T) T {
        \\    return p7(T, v);
        \\}
        \\fn p7(comptime T: type, v: T) T {
        \\    return p8(T, v);
        \\}
        \\fn p8(comptime T: type, v: T) T {
        \\    return p9(T, v);
        \\}
        \\fn p9(comptime T: type, v: T) T {
        \\    return p10(T, v);
        \\}
        \\fn p10(comptime T: type, v: T) T {
        \\    return p11(T, v);
        \\}
        \\fn p11(comptime T: type, v: T) T {
        \\    return p12(T, v);
        \\}
        \\fn p12(comptime T: type, v: T) T {
        \\    return p13(T, v);
        \\}
        \\fn p13(comptime T: type, v: T) T {
        \\    return p14(T, v);
        \\}
        \\fn p14(comptime T: type, v: T) T {
        \\    return p15(T, v);
        \\}
        \\fn p15(comptime T: type, v: T) T {
        \\    return p16(T, v);
        \\}
        \\fn p16(comptime T: type, v: T) T {
        \\    return p17(T, v);
        \\}
        \\fn p17(comptime T: type, v: T) T {
        \\    return p18(T, v);
        \\}
        \\fn p18(comptime T: type, v: T) T {
        \\    return p19(T, v);
        \\}
        \\fn p19(comptime T: type, v: T) T {
        \\    return dup(T, v);
        \\}
        \\fn keep(comptime T: type, v: T, n: u8) T {
        \\    switch (@typeInfo(T)) {
        \\        .@"union" => switch (n) {
        \\            0 => return dup(T, v),
        \\            1 => return dup(T, v),
        \\            2 => return dup(T, v),
        \\            else => return dup(T, v),
        \\        },
        \\        .@"enum" => return p0(T, v),
        \\        else => return v,
        \\    }
        \\}
        \\const E = enum {
        \\    a,
        \\    fn clone(e: E) E {
        \\        return e;
        \\    }
        \\};
        \\pub fn main() void {
        \\    _ = keep(E, .a, 0);
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable; // unreachable: the source holds each text asked
        }
    };
    const enum_call = (try calls.at(&facts, file, node.of(tree, "keep(E, .a, 0)"))).?;
    const keep = enum_call.callee.function;
    const clone = node.of(tree, "T.clone(v)");
    const crowded = for (try facts.parameterCopies(keep)) |copy| {
        if (copy.source != null and copy.source.?.node == clone and copy.crowded) break copy;
    } else return error.TestUnexpectedResult;
    // The enum's route reaches `dup` through 20 generics passing `v` on: `E.clone` gives an `E`.
    const value = (try facts.boundCopy(enum_call, keep, crowded)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value == .instance);
}

test "a choice holds each value once however many routes give it, two values a reader tells apart by any field stay two, and each value kept past the first spends one of the run's resolutions" {
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "const A = u8;\n" }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    // `!T` with `T` not settled, given by 1000 routes, each its own copy: one value (strand's
    // crowded walk held 281460 of it).
    var copies: [1000]Value = undefined;
    for (&copies) |*one| one.* = .{ .error_union = try facts.boxed(.{ .unknown = .comptime_dependent }) };
    const once = try facts.choose(&copies);
    try std.testing.expect(once == .error_union);
    try std.testing.expectEqual(Unknown.comptime_dependent, once.error_union.unknown);
    // Alike but for a reflected value's part, deep inside: two.
    const of = try facts.boxed(.{ .primitive = "u8" });
    const info: Value = .{ .error_union = try facts.boxed(.{ .reflected = .{ .of = of, .at = .info } }) };
    const size: Value = .{ .error_union = try facts.boxed(.{ .reflected = .{ .of = of, .at = .size } }) };
    const two = try facts.choose(&.{ info, size, info });
    try std.testing.expectEqual(2, two.alternatives.len);
    // Each kept past the first spends one: three kept with one left is past the budget; one
    // alone spends none.
    const third: Value = .{ .optional = of };
    facts.remaining = 0;
    try std.testing.expect(sameValue(info, try facts.choose(&.{ info, info })));
    try std.testing.expect(!facts.short);
    facts.remaining = 1;
    try std.testing.expectEqual(Unknown.budget, (try facts.choose(&.{ info, size, third })).unknown);
    try std.testing.expect(facts.short);
}

test "a crowded copy's walk reads each step once, however many routes reach it: 24 generics passing the value round in cycles, two routes from each, read within 5000 resolutions; one answer for the cycle whichever step is asked first, and none of it kept where the budget ran out inside it" {
    const w = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(w);
    try source.appendSlice(w, "fn dup(comptime T: type, v: T) T {\n    return T.clone(v);\n}\n");
    const k = 24;
    for (0..k) |i| {
        if (i == k - 1) {
            try source.print(w, "fn p{d}(comptime T: type, v: T, n: u8) T {{\n    if (n == 0) return dup(T, v);\n    return p0(T, v, n);\n}}\n", .{i});
        } else try source.print(w, "fn p{d}(comptime T: type, v: T, n: u8) T {{\n    if (n == 0) return p{d}(T, v, n);\n    return p{d}(T, v, n);\n}}\n", .{ i, i + 1, (i + 2) % k });
    }
    // `keep` enters the cycle at its first step, `keep2` at a step inside it.
    for ([_][]const u8{ "keep", "keep2" }, [_][]const u8{ "p0", "p12" }) |name, entry| try source.print(w,
        \\fn {s}(comptime T: type, v: T, n: u8) T {{
        \\    switch (@typeInfo(T)) {{
        \\        .@"union" => switch (n) {{
        \\            0 => return dup(T, v),
        \\            1 => return dup(T, v),
        \\            2 => return dup(T, v),
        \\            else => return dup(T, v),
        \\        }},
        \\        .@"enum" => return {s}(T, v, n),
        \\        else => return v,
        \\    }}
        \\}}
        \\
    , .{ name, entry });
    try source.appendSlice(w,
        \\const E = enum {
        \\    a,
        \\    fn clone(e: E) E {
        \\        return e;
        \\    }
        \\};
        \\pub fn main() void {
        \\    _ = keep(E, .a, 0);
        \\    _ = keep2(E, .a, 0);
        \\}
        \\
    );
    const Run = struct {
        project: Project,
        arena: std.heap.ArenaAllocator,
        facts: Facts,

        fn init(run: *@This(), bytes: []const u8) !void {
            run.project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = bytes }}, &.{}, .{});
            run.arena = .init(std.testing.allocator);
            run.facts = .{ .project = &run.project, .gpa = run.arena.allocator() };
        }

        fn deinit(run: *@This()) void {
            run.facts.deinit();
            run.arena.deinit();
            run.project.deinit();
        }

        /// What the crowded copy `name`'s binding in `main` makes holds.
        fn ask(run: *@This(), name: []const u8) !Value {
            const tree = &run.project.sources[0].file.tree;
            const file = run.project.sources[0].id;
            var text_buffer: [32]u8 = undefined;
            const text = try std.mem.print(&text_buffer, "{s}(E, .a, 0)", .{name});
            const call_node = for (0..tree.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, tree.getNodeSource(at), text)) break at;
            } else unreachable; // unreachable: main calls each
            const clone = for (0..tree.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, tree.getNodeSource(at), "T.clone(v)")) break at;
            } else unreachable; // unreachable: dup clones
            const call = (try calls.at(&run.facts, file, call_node)).?;
            const generic = call.callee.function;
            const crowded = for (try run.facts.parameterCopies(generic)) |copy| {
                if (copy.source != null and copy.source.?.node == clone and copy.crowded) break copy;
            } else return error.TestUnexpectedResult;
            return (try run.facts.boundCopy(call, generic, crowded)) orelse error.TestUnexpectedResult;
        }
    };
    // Each step read once: within 5000 resolutions, where reading it again along each route
    // ran out of them.
    var first: Run = undefined;
    try first.init(source.items);
    defer first.deinit();
    first.facts.remaining = 5000;
    const from_root = try first.ask("keep");
    try std.testing.expect(from_root == .instance);
    try std.testing.expect(!first.facts.short);
    try std.testing.expect((try first.facts.memo(Crowded)).found.count() >= k);
    try std.testing.expect(sameValue(from_root, try first.ask("keep2")));
    // Asked first from a step inside the cycle: the same answer.
    var member_first: Run = undefined;
    try member_first.init(source.items);
    defer member_first.deinit();
    member_first.facts.remaining = 5000;
    try std.testing.expect(sameValue(from_root, try member_first.ask("keep2")));
    try std.testing.expect(sameValue(from_root, try member_first.ask("keep")));
    // The budget runs out at a step in the middle of the cycle: the whole of it is
    // unknown(budget), and none of it is kept, so asked again from another step with budget,
    // the cycle is read whole.
    var cut: Run = undefined;
    try cut.init(source.items);
    defer cut.deinit();
    // A read of the whole spends 375 resolutions here: 200 run out partway through it.
    cut.facts.remaining = 200;
    try std.testing.expectEqual(Unknown.budget, (try cut.ask("keep")).unknown);
    try std.testing.expect(cut.facts.short);
    try std.testing.expectEqual(0, (try cut.facts.memo(Crowded)).found.count());
    cut.facts.short = false;
    cut.facts.remaining = 5000;
    try std.testing.expect(sameValue(from_root, try cut.ask("keep2")));
    try std.testing.expect(!cut.facts.short);
}

test "a crowded copy's answer is kept per set of settled assumptions: asked under another set it is read again, never given the one kept under the first" {
    const source =
        \\fn dup(comptime T: type, v: T) T {
        \\    return T.clone(v);
        \\}
        \\fn keep(comptime T: type, v: T, n: u8) T {
        \\    switch (@typeInfo(T)) {
        \\        .@"union" => switch (n) {
        \\            0 => return dup(T, v),
        \\            1 => return dup(T, v),
        \\            2 => return dup(T, v),
        \\            else => return dup(T, v),
        \\        },
        \\        .@"enum" => return dup(T, v),
        \\        else => return v,
        \\    }
        \\}
        \\const E = enum {
        \\    a,
        \\    fn clone(e: E) E {
        \\        return e;
        \\    }
        \\};
        \\pub fn main() void {
        \\    _ = keep(E, .a, 0);
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable; // unreachable: the source holds each text asked
        }
    };
    const enum_call = (try calls.at(&facts, file, node.of(tree, "keep(E, .a, 0)"))).?;
    const keep = enum_call.callee.function;
    const clone = node.of(tree, "T.clone(v)");
    const crowded = for (try facts.parameterCopies(keep)) |copy| {
        if (copy.source != null and copy.source.?.node == clone and copy.crowded) break copy;
    } else return error.TestUnexpectedResult;
    const plain = (try facts.boundCopy(enum_call, keep, crowded)) orelse return error.TestUnexpectedResult;
    const kept = (try facts.memo(Crowded)).found.count();
    try std.testing.expect(kept != 0);
    // Another set in force: none of the first set's answers is given; the steps are read
    // again, and kept beside them.
    try facts.settled.append(facts.gpa, .{ .held = &.{.{ .parameter = keep, .value = .{ .boolean = true } }} });
    facts.assumed = @fromBackingInt(@as(u32, @intCast(facts.settled.items.len - 1)));
    const under = (try facts.boundCopy(enum_call, keep, crowded)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(2 * kept, (try facts.memo(Crowded)).found.count());
    try std.testing.expect(sameValue(plain, under));
}

test "a copy crowded past its routes is read along the routes its binding compiles, kept or not" {
    const source =
        \\fn dup(comptime T: type, v: T) T {
        \\    return T.clone(v);
        \\}
        \\fn keep(comptime T: type, v: T, n: u8) T {
        \\    switch (@typeInfo(T)) {
        \\        .@"union" => switch (n) {
        \\            0 => return dup(T, v),
        \\            1 => return dup(T, v),
        \\            2 => return dup(T, v),
        \\            else => return dup(T, v),
        \\        },
        \\        .@"enum" => return dup(T, v),
        \\        else => return v,
        \\    }
        \\}
        \\const E = enum {
        \\    a,
        \\    fn clone(e: E) E {
        \\        return e;
        \\    }
        \\};
        \\pub fn main() void {
        \\    _ = keep(bool, true, 0);
        \\    _ = keep(E, .a, 0);
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const file = project.sources[0].id;
    const node = struct {
        fn of(t: *const Ast, text: []const u8) Ast.Node.Index {
            for (0..t.nodes.len) |i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (std.mem.eql(u8, t.getNodeSource(at), text)) return at;
            }
            unreachable; // unreachable: the source holds each text asked
        }
    };
    const plain = (try calls.at(&facts, file, node.of(tree, "keep(bool, true, 0)"))).?;
    const keep = plain.callee.function;
    const clone = node.of(tree, "T.clone(v)");
    const crowded = for (try facts.parameterCopies(keep)) |copy| {
        if (copy.source != null and copy.source.?.node == clone and copy.crowded) break copy;
    } else return error.TestUnexpectedResult;
    // A bool's instantiation compiles none of the five routes through `dup`.
    try std.testing.expectEqual(@as(?Value, null), try facts.boundCopy(plain, keep, crowded));
    // An enum's compiles the fifth, on the enum's prong, past the four routes kept (the
    // union's): `E.clone` gives an `E`.
    const enum_call = (try calls.at(&facts, file, node.of(tree, "keep(E, .a, 0)"))).?;
    const value = (try facts.boundCopy(enum_call, keep, crowded)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value == .instance);
}

/// The function or container-level constant `name` of the project's `source`th file, for the
/// tests of what code the walk did not read analyzes (`lazilyAnalyzed`).
fn testDecl(project: *const Project, source: usize, name: []const u8) Decl {
    const model = &project.sources[source].model;
    for (model.declarations, 0..) |d, i| if (std.mem.eql(u8, d.name, name) and (d.kind == .function or d.kind == .variable)) return .{ .file = project.sources[source].id, .index = @fromBackingInt(@intCast(i)) };
    unreachable; // unreachable: the source declares each name asked
}

test "code the walk did not read is analyzed where a site that may name it lies in analyzed code: a name, a member, a decl literal, an @field of a type, an export or a comptime block of a file it imports; a cycle no root reaches is analyzed nowhere" {
    const root =
        \\const std = @import("std");
        \\const missing = @import("missing");
        \\pub fn main() void {
        \\    missing.T.viaName();
        \\}
    ;
    const library =
        \\const missing = @import("missing");
        \\const Kind = struct {
        \\    tag: u8,
        \\    pub const default: Kind = .{ .tag = 0 };
        \\    pub fn make() Kind {
        \\        return .{ .tag = 1 };
        \\    }
        \\};
        \\pub const Holder = struct {
        \\    pub fn first() void {}
        \\    pub fn second() void {}
        \\};
        \\pub const Kept = struct {
        \\    pub fn kept() void {}
        \\};
        \\pub fn viaName() void {
        \\    idTarget();
        \\    Kept.kept();
        \\    const k: Kind = .default;
        \\    const m: Kind = .make();
        \\    _ = .{ k, m };
        \\    inline for (@typeInfo(Holder).@"struct".decls) |d| _ = @field(Holder, d.name);
        \\    missing.U.viaMember();
        \\    _ = @import("other.zig").from_other;
        \\    liveJ();
        \\}
        \\fn idTarget() void {}
        \\fn deadCaller() void {
        \\    deadTarget();
        \\    _ = @import("dead.zig");
        \\}
        \\fn deadTarget() void {}
        \\fn cycA() void {
        \\    cycB();
        \\}
        \\fn cycB() void {
        \\    cycA();
        \\}
        \\fn liveH() void {
        \\    liveI();
        \\}
        \\fn liveI() void {
        \\    liveH();
        \\}
        \\fn liveJ() void {
        \\    liveH();
        \\}
    ;
    const other =
        \\pub const from_other = 1;
        \\pub fn viaMember() void {}
        \\export fn exported() void {}
        \\comptime {
        \\    _ = comptimeTarget;
        \\}
        \\fn comptimeTarget() void {}
        \\fn otherUnused() void {}
    ;
    const dead_file =
        \\export fn deadExport() void {}
        \\comptime {
        \\    _ = deadComptime;
        \\}
        \\fn deadComptime() void {}
    ;
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = root, .absent = &.{"missing"} },
        .{ .name = "std/std.zig", .bytes = library, .selected = false, .absent = &.{"missing"} },
        .{ .name = "std/other.zig", .bytes = other, .selected = false },
        .{ .name = "std/dead.zig", .bytes = dead_file, .selected = false },
    }, &.{
        .{ .from = 0, .spelling = "std", .target = 1 },
        .{ .from = 1, .spelling = "other.zig", .target = 2 },
        .{ .from = 1, .spelling = "dead.zig", .target = 3 },
    }, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const found = try facts.analysis();
    try std.testing.expect(!found.everything);
    try std.testing.expectEqual(0, found.limits.items.len);
    // The walk reaches none of std's: `missing.T.viaName()` names `viaName` on an unknown
    // holder (Zig's member lookup), and a reader's question finds the rest backwards.
    try std.testing.expect(!found.reached.contains(testDecl(&project, 1, "idTarget")));
    // The cycle first: `liveH`'s site in `liveI` reads `liveI` while `liveH` is open (no, held),
    // then its site in `liveJ`, which `viaName` calls: yes, and `liveI` is asked again.
    try std.testing.expect(try facts.analyzed(testDecl(&project, 1, "liveH")));
    try std.testing.expect(try facts.analyzed(testDecl(&project, 1, "liveI")));
    try std.testing.expect(try facts.analyzed(testDecl(&project, 1, "liveJ")));
    try std.testing.expect(!try facts.analyzed(testDecl(&project, 1, "cycA")));
    try std.testing.expect(!try facts.analyzed(testDecl(&project, 1, "cycB")));
    for ([_]struct { usize, []const u8 }{
        .{ 1, "viaName" }, // a member of an unknown holder the walk met
        .{ 1, "idTarget" }, // a name
        .{ 1, "kept" }, // a member of a type
        .{ 1, "default" }, // a decl literal
        .{ 1, "make" }, // a decl literal called
        .{ 1, "first" }, // @field of a type, its name computed: each declaration
        .{ 1, "second" },
        .{ 2, "viaMember" }, // a member of an unknown holder in code read lazily
        .{ 2, "exported" }, // an export of a file an import read lazily enters
        .{ 2, "comptimeTarget" }, // a name in that file's comptime block
    }) |each| {
        errdefer std.debug.print("not analyzed: {s}\n", .{each[1]});
        try std.testing.expect(try facts.analyzed(testDecl(&project, each[0], each[1])));
    }
    for ([_]struct { usize, []const u8 }{
        .{ 1, "deadCaller" },
        .{ 1, "deadTarget" },
        .{ 2, "otherUnused" },
        .{ 3, "deadExport" }, // a file only code nothing analyzes imports
        .{ 3, "deadComptime" },
    }) |each| {
        errdefer std.debug.print("analyzed: {s}\n", .{each[1]});
        try std.testing.expect(!try facts.analyzed(testDecl(&project, each[0], each[1])));
    }
    try std.testing.expect(try facts.fileAnalyzed(project.sources[2].id));
    try std.testing.expect(!try facts.fileAnalyzed(project.sources[3].id));
}

test "an @field whose name is computed of a holder that does not resolve, in code read lazily, may name every declaration: each is analyzed" {
    const root =
        \\const std = @import("std");
        \\const missing = @import("missing");
        \\pub fn main() void {
        \\    missing.T.viaName();
        \\}
    ;
    const library =
        \\const missing = @import("missing");
        \\pub fn viaName() void {
        \\    inline for (@typeInfo(missing.T).@"struct".decls) |d| _ = @field(missing.T, d.name);
        \\}
        \\fn anyDecl() void {}
    ;
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = root, .absent = &.{"missing"} },
        .{ .name = "std/std.zig", .bytes = library, .selected = false, .absent = &.{"missing"} },
    }, &.{.{ .from = 0, .spelling = "std", .target = 1 }}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    try std.testing.expect(!(try facts.analysis()).everything);
    try std.testing.expect(try facts.analyzed(testDecl(&project, 1, "anyDecl")));
}

test "a reader's question past its steps, or code read lazily that imports what no file holds, answers that it may be analyzed" {
    const root =
        \\const std = @import("std");
        \\const missing = @import("missing");
        \\pub fn main() void {
        \\    missing.T.viaName();
        \\}
    ;
    const library =
        \\pub fn viaName() void {
        \\    _ = @import("nowhere");
        \\}
        \\fn deadCaller() void {
        \\    deadTarget();
        \\}
        \\fn deadTarget() void {}
    ;
    const lone =
        \\export fn alone() void {}
    ;
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = root, .absent = &.{"missing"} },
        .{ .name = "std/std.zig", .bytes = library, .selected = false },
        .{ .name = "std/lone.zig", .bytes = lone, .selected = false },
    }, &.{.{ .from = 0, .spelling = "std", .target = 1 }}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    // `@import("nowhere")` in `viaName`, which is analyzed: any file may be imported.
    try std.testing.expect(try facts.analyzed(testDecl(&project, 2, "alone")));
    try std.testing.expect(!try facts.analyzed(testDecl(&project, 1, "deadTarget")));
    var short: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer short.deinit();
    (try short.builtAnalysis()).lazy.limit = 0;
    try std.testing.expect(try short.analyzed(testDecl(&project, 1, "deadTarget")));
}
