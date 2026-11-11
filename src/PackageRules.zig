//! The rules a package declares in a module root (glint-design §12): `pub const lint_rules = .{
//! .version = 2, ... }`, read once per root as the caller states the root's package (its name and
//! fingerprint), every reference through the one resolver. A rule asks this reader; none reads a
//! declaration's spelling to know what a package declares.
//!
//! Version 2 is two entry kinds and the rules that read them: `.rules` (each rule's id, name,
//! kind, what it reads, its default), `.governed` (a type, its internal fields, its exits) and
//! `.replaces` (a declaration, builtin or extern symbol a package's answer stands for).
const std = @import("std");
const Ast = std.zig.Ast;
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
const Inventory = @import("Rule.zig");

/// The vocabulary's version this reader knows. A root declaring another is read as no rules,
/// with the version a problem: a finding in the declarer.
pub const version: u64 = 2;
/// The roles-and-pairs vocabulary, read only until the rules that read roles are gone.
const legacy_version: u64 = 1;

/// A rule a package declares (`.rules`): the id a selection and a suppression name, the name its
/// report gives, its kind, the entries it reads, whether a run selects it unasked, and its purpose.
pub const Declared = struct {
    id: []const u8,
    name: []const u8,
    kind: Kind,
    reads: Reads,
    default: bool,
    purpose: []const u8,
    file: Project.FileId,
    node: Ast.Node.Index,

    pub const Kind = Inventory.Kind;
    pub const Reads = Inventory.Reads;
};

/// A type only its package touches inside (`.governed`).
pub const Governance = struct {
    type: Reference,
    /// The containers the type is: itself, or each one a type function returns, which every
    /// instance is.
    containers: []const Facts.Container,
    /// Each `.internal` field's declaration, in every container.
    internal: []const Facts.Decl,
    /// Each `.exits` member's declaration, in every container: where a governed value's raw
    /// content leaves it.
    exits: []const Facts.Decl,
    file: Project.FileId,
    node: Ast.Node.Index,
};

/// What a package's answer stands for (`.replaces`), under the rule it names.
pub const Replacement = struct {
    /// The id of the rule, one the package declares to read `replaces`.
    rule: []const u8,
    target: Form,
    /// `.held = .field`: the target counts only as a struct field's type held by value.
    held: bool = false,
    with: []const Reference = &.{},
    why: []const u8 = "",
    /// Where the declaring package itself may use the target; null for the whole package.
    door: ?[]const Reference = null,
    file: Project.FileId,
    node: Ast.Node.Index,

    pub const Form = union(enum) {
        /// `.decl`: the declaration, or the name's declaration in each per-target holder.
        decl: []const Facts.Decl,
        /// `.members = C, .except = .{...}`: each function declared directly in `C`, less those.
        members: []const Facts.Decl,
        /// `.field = .{ .type = T, .name = .f }`: the field's declaration.
        field: Facts.Decl,
        /// `.builtin = .@"@name"`, one of the language's builtins, written with its `@`.
        builtin: []const u8,
        /// `.symbol = "name"`: every `extern` bound to that link name.
        symbol: []const u8,
        /// It does not resolve: drift in the declarer, reported where it is written.
        unresolved,
    };

    /// The declarations a reference, call or field type may resolve into to be the target.
    pub fn declarations(self: *const Replacement) []const Facts.Decl {
        return switch (self.target) {
            .decl, .members => |all| all,
            .field => |*one| @as(*const [1]Facts.Decl, one),
            .builtin, .symbol, .unresolved => &.{},
        };
    }
};

/// A package as the caller states one of its files to be: the name and fingerprint its
/// `build.zig.zon` gives, wherever its tree is (a fork's copy under bay's cache is the package).
/// A file the caller states nothing of is in the unnamed package, with every other such file.
pub const Identity = struct {
    name: []const u8,
    fingerprint: ?u64,

    pub fn of(project: *const Project, file: Project.FileId) Identity {
        const input = project.at(file).input;
        return .{ .name = input.package, .fingerprint = input.fingerprint };
    }

    pub fn eql(a: Identity, b: Identity) bool {
        return a.fingerprint == b.fingerprint and std.mem.eql(u8, a.name, b.name);
    }
};

/// A declaration an entry names.
pub const Reference = union(enum) {
    /// The declaration, a member of a type function's returned container included: a call
    /// matches it by declaration in any instantiation (`Facts.calls`), never by its name.
    decl: Facts.Decl,
    /// It does not resolve: in a consumer the rules that need it are undecided; in the
    /// declaring package it is drift.
    unresolved,
    /// It resolves outside the declaring package (std's aside for `.std`): a package declares
    /// rules only for what it declares, so the declarer's own lint reports it.
    foreign: Facts.Decl,
    /// A member of std's that each target declares in a holder of its own (`std.c.F.FULLFSYNC`,
    /// `c.F` a different struct per target): that name's declaration in each holder that has one.
    each_target: []const Facts.Decl,

    pub fn declaration(self: Reference) ?Facts.Decl {
        return if (self == .decl) self.decl else null;
    }

    /// Every declaration it names: the one, or each target's.
    pub fn declarations(self: *const Reference) []const Facts.Decl {
        return switch (self.*) {
            .decl => |*one| @as(*const [1]Facts.Decl, one),
            .each_target => |all| all,
            .unresolved, .foreign => &.{},
        };
    }
};

/// A declaration the package's replacement stands for (P006's): a std declaration (`.std`), or an
/// external symbol by its link name (`.symbol = "fsync"`), which every `extern` of it binds; one or
/// the other.
pub const Replace = struct { std: ?Reference = null, symbol: ?[]const u8 = null, with: Reference, why: []const u8 };
/// A declaration of the package's to move off (Z011's).
/// A function of the package that itself does the work a replacement stands for (`.door`, P006):
/// with every `.with`, the package's door. `node` is where the list names it.
pub const Door = struct { reference: Reference, file: Project.FileId, node: Ast.Node.Index };

pub const Deprecated = struct { decl: Reference, with: ?Reference, why: []const u8 };
/// What a type means: its role, by the enum literal's name, and the fields only the package may
/// touch (A001's), by name.
pub const Role = struct { type: Reference, role: []const u8, internal: []const []const u8 };
/// An obligation no body shows: what makes it, and what ends, moves or checks it.
pub const Pair = struct {
    /// Where the pair is written.
    file: Project.FileId = undefined,
    node: Ast.Node.Index = undefined,
    /// The function whose result owes it; null where `type` names the owing type instead.
    acquire: ?Reference = null,
    /// The type every value of which owes it (`Secret`, `Guarded(T).Guard`): its operations are
    /// written as its members (`.deinit`), each resolved once in its container.
    type: ?Reference = null,
    /// What discharges it.
    release: []const Reference = &.{},
    /// What moves it off this value, each with where to (`Transfer`).
    transfer: []const Transfer = &.{},
    /// What ends the value, checking that a release came first (`MustUse.deinit`).
    teardown: []const Reference = &.{},
    /// Refused as written (`Problem.Why.refused`): what its operations do is not known.
    refused: bool = false,
};

/// A member that moves an obligation off its value, and where it goes, read from the member's
/// declaration, never declared beside it: to the call's result where the declared result (through
/// `!` and `?`) is a pair's type (`Guard.handOff` returning `Handoff`); else into the one parameter,
/// the receiver aside, that points to a pair's type (`moveInto(self, destination: *Self)`).
pub const Transfer = struct {
    member: Reference,
    to: union(enum) {
        /// The call's result owes it: on success where the result is an error union, and only when
        /// not null where it is optional; otherwise the source still owes it.
        result,
        /// The parameter at this position (the receiver counted) is given it.
        argument: usize,
        /// Not settled: the member does not resolve, or the pair was refused.
        unknown,
    } = .unknown,
};

/// Why part of a root's rules could not be read, and where.
pub const Problem = struct {
    file: Project.FileId,
    node: Ast.Node.Index,
    why: Why,
    /// The part of the rules it is in: one in a replacement or a deprecation leaves the roles and
    /// pairs read (`publication`), the declarer's to fix where its own lint reports it.
    part: Part = .roles,

    pub const Part = enum { roles, replaces, deprecated, rules, governed };

    pub const Why = enum {
        /// `.version` is not this reader's (`version`), or an `.include` is of another version
        /// than the root: the rules are not read.
        unknown_version,
        /// A replacement names a rule the package does not declare, or one declared to read
        /// something else.
        unknown_rule,
        /// A rule id the package declares twice.
        duplicate_rule,
        /// A `.builtin` the language does not have.
        unknown_builtin,
        /// A field the vocabulary does not have.
        unknown_field,
        /// A value not of the form the vocabulary gives it (a list, a string, an enum literal).
        malformed,
        /// A reference that does not resolve.
        unresolved,
        /// A reference to a declaration outside the declaring package.
        foreign,
        /// A pair refused as written: an operation that is no function, a transfer whose
        /// destination its declaration does not settle (no parameter or several), or a teardown
        /// with no release to check for.
        refused,
        /// A role no pack of the run reads (`Facts.role_names`): a misspelt role would leave its
        /// type plain, which clears its sites.
        unknown_role,
    };
};

/// One root's rules, its `.include`s merged in, each declaration once.
pub const Rules = struct {
    package: Identity,
    root: Project.FileId,
    /// Null where the root declares no `lint_rules`.
    declared: ?Facts.Decl = null,
    /// The vocabulary's version the root declares; 0 where it declares none this reader reads.
    version: u64 = 0,
    rule_table: []const Declared = &.{},
    governance: []const Governance = &.{},
    replacements: []const Replacement = &.{},
    replaces: []const Replace = &.{},
    door: []const Door = &.{},
    deprecated: []const Deprecated = &.{},
    roles: []const Role = &.{},
    pairs: []const Pair = &.{},
    problems: []const Problem = &.{},
};

const Memo = struct { roots: std.AutoHashMapUnmanaged(Project.FileId, *const Rules) = .empty };

/// The rules `root`, a module's root file, declares: read once for the run.
pub fn of(facts: *Facts, root: Project.FileId) Facts.ResolveError!*const Rules {
    const memo = try facts.memo(Memo);
    if (memo.roots.get(root)) |known| return known;
    var reader: Reader = .{ .facts = facts, .package = .of(facts.project, root) };
    const found = try facts.gpa.create(Rules);
    found.* = .{ .package = reader.package, .root = root };
    if (facts.member(facts.rootOf(root), "lint_rules")) |decl| {
        found.declared = decl;
        try reader.declaration(decl);
        try reader.settlePairs();
        try reader.settleRules();
        found.version = reader.version;
        found.rule_table = try reader.rule_table.toOwnedSlice(facts.gpa);
        found.governance = try reader.governance.toOwnedSlice(facts.gpa);
        found.replacements = try reader.replacements.toOwnedSlice(facts.gpa);
        found.replaces = try reader.replaces.toOwnedSlice(facts.gpa);
        found.door = try reader.door.toOwnedSlice(facts.gpa);
        found.deprecated = try reader.deprecated.toOwnedSlice(facts.gpa);
        found.roles = try reader.roles.toOwnedSlice(facts.gpa);
        found.pairs = try reader.pairs.toOwnedSlice(facts.gpa);
        found.problems = try reader.problems.toOwnedSlice(facts.gpa);
    }
    try memo.roots.put(facts.gpa, root, found);
    return found;
}

/// The first id the run gives a package's rule: below it are glint's own (under 1000) and the
/// rules a caller compiles in.
pub const first_package_id: u16 = 2000;

/// The rules the run's packages declare (`.rules`), as the run's rule table holds them: each
/// root-level `lint_rules` in the project read once (`of`, its includes merged), a rule its
/// includes reach from two roots counted once, ordered by id and given ids from
/// `first_package_id`. Two packages declaring one id is `DuplicateRule`: a run reads one rule
/// under a name; more rules than ids are left is `TooManyRules`.
pub fn table(facts: *Facts) (Facts.ResolveError || error{ DuplicateRule, TooManyRules })![]const Inventory.Definition {
    var found: std.ArrayList(Declared) = .empty;
    for (facts.project.sources) |*source| {
        if (source.input.kind == .zon) continue;
        if (facts.member(facts.rootOf(source.id), "lint_rules") == null) continue;
        for ((try of(facts, source.id)).rule_table) |declared| {
            const same = for (found.items) |known| {
                if (known.file == declared.file and known.node == declared.node) break true;
            } else false;
            if (same) continue;
            for (found.items) |known| if (std.mem.eql(u8, known.id, declared.id)) return error.DuplicateRule;
            try found.append(facts.gpa, declared);
        }
    }
    std.mem.sort(Declared, found.items, {}, idLess);
    if (found.items.len > std.math.maxInt(u16) - first_package_id) return error.TooManyRules;
    const definitions = try facts.gpa.alloc(Inventory.Definition, found.items.len);
    for (found.items, definitions, 0..) |declared, *definition, i| definition.* = .{
        .id = @fromBackingInt(first_package_id + @as(u16, @intCast(i))),
        .name = declared.id,
        .group = .family_policy,
        .purpose = declared.purpose,
        .declared = .{ .package = facts.project.at(declared.file).input.package, .kind = declared.kind, .reads = declared.reads, .default = declared.default },
    };
    return definitions;
}
fn idLess(_: void, a: Declared, b: Declared) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

/// The module roots the program imports by a module's name (not a file's path), each once.
pub fn roots(facts: *Facts) Facts.ResolveError![]const Project.FileId {
    var found: std.ArrayList(Project.FileId) = .empty;
    for (facts.project.imports) |mapping| {
        if (std.mem.endsWith(u8, mapping.spelling, ".zig") or std.mem.endsWith(u8, mapping.spelling, ".zon")) continue;
        if (std.mem.findScalar(Project.FileId, found.items, mapping.target) != null) continue;
        try found.append(facts.gpa, mapping.target);
    }
    return found.toOwnedSlice(facts.gpa);
}

/// A library's declared roles in this project (`publication`): what its package's roots declare.
/// Roles are the caller's enum values; the reader never interprets them.
pub const Publication = struct {
    entries: []const Entry,
    /// Where the roles are not all read: undecided where a file imports that root, never silence.
    gaps: []const Gap,
    /// The library's own files: those of its package's identity. A file republishing its API,
    /// or a copy vendored without its manifest, stays the program's.
    files: []const Project.FileId,
    /// The obligations no body shows, each pair as its root declares it (`of`).
    pairs: []const Pair = &.{},
};
/// A role on a declaration, with the fields only its package touches (`.internal`, A001's).
pub const Entry = struct { role: u32, target: Target, internal: []const []const u8 = &.{} };
pub const Target = union(enum) { function: Facts.Decl, container: Facts.Container };
/// A root of the library whose roles are not all read: it declares no `lint_rules` (`problem`
/// null), or part of what it declares could not be read (`Problem`, where it is written).
/// Reported where a file imports that root, under whatever name.
pub const Gap = struct { root: Project.FileId, problem: ?Problem };

const Publications = struct { found: std.AutoHashMapUnmanaged(u64, *const Publication) = .empty };

/// What `library`'s package declares (`Library`): each role its roots' `lint_rules` give (`of`)
/// that the library's `Role` names, on the declaration it names; a type function's role on each
/// container it returns too (`Facts.returnedContainers`), which its instances are. A root that
/// declares no `lint_rules`, or whose rules are not all read (a version this reader does not know,
/// a reference that does not resolve, a role no pack reads), is a gap: its roles may be missing,
/// so a rule reading them is undecided where that root is imported, never plain. Found once per
/// run and shared by every rule.
pub fn publication(facts: *Facts, comptime R: type, library: @import("Library.zig").Library(R)) Facts.ResolveError!*const Publication {
    const vocabulary = comptime std.hash.Wyhash.hash(0, @typeName(R));
    const keyed = vocabulary ^ library.package.fingerprint;
    const memo = try facts.memo(Publications);
    if (memo.found.get(keyed)) |known| return known;
    var entries: std.ArrayList(Entry) = .empty;
    var gaps: std.ArrayList(Gap) = .empty;
    var pairs: std.ArrayList(Pair) = .empty;
    for (try facts.packageRoots(library.package)) |root| {
        const rules = try of(facts, root);
        if (rules.declared == null) try gaps.append(facts.gpa, .{ .root = root, .problem = null });
        // A replacement or a deprecation that does not resolve leaves the roles read: the
        // declarer's own lint reports it, and P006 skips the entry.
        for (rules.problems) |problem| if (problem.part == .roles) try gaps.append(facts.gpa, .{ .root = root, .problem = problem });
        try pairs.appendSlice(facts.gpa, rules.pairs);
        for (rules.roles) |declared| {
            const role_value = roleValue(R, declared.role) orelse continue;
            const decl = declared.type.declaration() orelse continue;
            // A declaration that is a choice (a type chosen per build): each part the role's.
            const declared_value = try facts.declaration(decl);
            for (Facts.valueParts(&declared_value)) |part| switch (part) {
                .function => |function| {
                    try entries.append(facts.gpa, .{ .role = role_value, .target = .{ .function = function }, .internal = declared.internal });
                    // The container a type function returns is also its type: instances declared
                    // with it are the role's, each container it may return where it chooses one
                    // by a comptime option (aegis 0.3's `SlotPool(T, Tag, options)`).
                    if (try facts.template(function)) |returned| for (try Facts.returnedContainers(facts.gpa, returned)) |made| {
                        try entries.append(facts.gpa, .{ .role = role_value, .target = .{ .container = .{ .file = made.file, .scope = made.scope } }, .internal = declared.internal });
                    };
                },
                .container => |made| try entries.append(facts.gpa, .{ .role = role_value, .target = .{ .container = .{ .file = made.file, .scope = made.scope } }, .internal = declared.internal }),
                .alternatives => unreachable, // unreachable: valueParts gives no choice as a part
                // A role on what is no type and no function: the declarer's own lint reports
                // the form; for its consumers the role is not read.
                else => try gaps.append(facts.gpa, .{ .root = root, .problem = .{ .file = decl.file, .node = facts.project.at(decl.file).model.declarations[@backingInt(decl.index)].node, .why = .malformed } }),
            };
        }
    }
    var files: std.ArrayList(Project.FileId) = .empty;
    for (facts.project.sources) |*source| if (facts.ofPackage(source.id, library.package)) try files.append(facts.gpa, source.id);
    const result = try facts.gpa.create(Publication);
    result.* = .{ .entries = entries.items, .gaps = gaps.items, .files = files.items, .pairs = pairs.items };
    try memo.found.put(facts.gpa, keyed, result);
    return result;
}

/// What a call of a declaration does to an obligation a pair declares (`Pair`): discharges it,
/// moves it (to the call's result, or into an argument), checks at the value's end that it was
/// discharged, or none of these (`operation` answers null). A refused pair's operations, and a
/// transfer whose destination did not settle, are `unknown`.
pub const Operation = union(enum) { release, transfer: @FieldType(Transfer, "to"), teardown, unknown };

/// What `callee`, by its declaration, does to an obligation `library`'s package declares.
pub fn operation(facts: *Facts, comptime R: type, library: @import("Library.zig").Library(R), callee: Facts.Decl) Facts.ResolveError!?Operation {
    const found = try publication(facts, R, library);
    for (found.pairs) |pair| {
        for (pair.release) |each| if (namesDecl(each, callee)) return if (pair.refused) .unknown else .release;
        for (pair.transfer) |move| if (namesDecl(move.member, callee)) return if (pair.refused or move.to == .unknown) .unknown else .{ .transfer = move.to };
        for (pair.teardown) |each| if (namesDecl(each, callee)) return if (pair.refused) .unknown else .teardown;
    }
    return null;
}
fn namesDecl(reference: Reference, decl: Facts.Decl) bool {
    return std.meta.eql(reference.declaration() orelse return false, decl);
}

/// The value of the tag of `Roles` named `name`, or null where it names none: a role another pack reads.
fn roleValue(comptime Roles: type, name: []const u8) ?u32 {
    const info = @typeInfo(Roles).@"enum";
    inline for (info.field_names, info.field_values) |field, value| if (std.mem.eql(u8, field, name)) return value;
    return null;
}

/// The role `library`'s package declares for a function declaration, or a type or instance of a
/// container with a role, seen through pointers, optionals and error unions; of a choice, the
/// role every part agrees on.
pub fn role(facts: *Facts, comptime R: type, library: @import("Library.zig").Library(R), value: Facts.Value) Facts.ResolveError!?R {
    const raw = (try roleNumber(facts, R, library, value)) orelse return null;
    return @as(R, @fromBackingInt(@intCast(raw)));
}

/// The number of the role `role` reads, compared as a number (no value of the library's `R` is
/// compared or copied): of a choice, the one every part agrees on, none where they
/// differ or one has none.
fn roleNumber(facts: *Facts, comptime R: type, library: @import("Library.zig").Library(R), value: Facts.Value) Facts.ResolveError!?@FieldType(Entry, "role") {
    if (value == .alternatives) {
        if (value.alternatives.len == 0) return null;
        const first = ((try entryOf(facts, R, library, value.alternatives[0])) orelse return null).role;
        for (value.alternatives[1..]) |part| {
            const other = ((try entryOf(facts, R, library, part)) orelse return null).role;
            if (other != first) return null;
        }
        return first;
    }
    return ((try entryOf(facts, R, library, value)) orelse return null).role;
}

/// The fields only `library`'s package touches of a value's type (`.internal`), where its type is
/// one the package gives a role, seen as `role` sees it; null where it is none.
pub fn internalOf(facts: *Facts, comptime R: type, library: @import("Library.zig").Library(R), value: Facts.Value) Facts.ResolveError!?[]const []const u8 {
    const found = (try entryOf(facts, R, library, value)) orelse return null;
    return found.internal;
}

/// The entry of the declaration `value` is, or is a type or instance of.
fn entryOf(facts: *Facts, comptime R: type, library: @import("Library.zig").Library(R), value: Facts.Value) Facts.ResolveError!?Entry {
    const found = try publication(facts, R, library);
    var current = value;
    while (true) switch (current) {
        .pointer => |inner| current = inner.child.*,
        .array, .optional, .error_union => |inner| current = inner.*,
        .function => |decl| {
            for (found.entries) |entry| if (entry.target == .function and std.meta.eql(entry.target.function, decl)) return entry;
            return null;
        },
        .container, .instance => |c| {
            for (found.entries) |entry| if (entry.target == .container and entry.target.container.file == c.file and entry.target.container.scope == c.scope) return entry;
            return null;
        },
        // A choice is no one declaration's entry: `role` reads it part by part.
        .alternatives => return null,
        else => return null,
    };
}

const Reader = struct {
    facts: *Facts,
    package: Identity,
    /// Each `lint_rules` read, so an `.include` cycle or repeat is read once.
    seen: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty,
    replaces: std.ArrayList(Replace) = .empty,
    door: std.ArrayList(Door) = .empty,
    deprecated: std.ArrayList(Deprecated) = .empty,
    /// The part of the rules being read, which a problem found there records.
    part: Problem.Part = .roles,
    roles: std.ArrayList(Role) = .empty,
    pairs: std.ArrayList(Pair) = .empty,
    problems: std.ArrayList(Problem) = .empty,
    /// The root's version, which every `.include` shares; 0 until the root's is read.
    version: u64 = 0,
    rule_table: std.ArrayList(Declared) = .empty,
    governance: std.ArrayList(Governance) = .empty,
    replacements: std.ArrayList(Replacement) = .empty,
    /// Where each replacement names its rule, settled once every `.rules` is read.
    named_rules: std.ArrayList(struct { file: Project.FileId, node: Ast.Node.Index }) = .empty,

    const Error = Facts.ResolveError;

    fn tree(r: *const Reader, file: Project.FileId) *const Ast {
        return &r.facts.project.at(file).file.tree;
    }

    fn problem(r: *Reader, file: Project.FileId, node: Ast.Node.Index, why: Problem.Why) Error!void {
        try r.problems.append(r.facts.gpa, .{ .file = file, .node = node, .why = why, .part = r.part });
    }

    /// Reads one `lint_rules` declaration, once.
    fn declaration(r: *Reader, decl: Facts.Decl) Error!void {
        if ((try r.seen.getOrPut(r.facts.gpa, decl)).found_existing) return;
        const record = r.facts.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        const t = r.tree(decl.file);
        const init = (t.fullVarDecl(record.node) orelse return r.problem(decl.file, record.node, .malformed)).ast.init_node.unwrap() orelse
            return r.problem(decl.file, record.node, .malformed);
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = t.fullStructInit(&buffer, init) orelse return r.problem(decl.file, init, .malformed);
        // The version first: a root of another version is not read at all, nor an include of
        // a version other than its root's.
        var declared: u64 = 0;
        for (literal.ast.fields) |field| if (std.mem.eql(u8, fieldName(t, field), "version")) {
            if (t.nodeTag(field) == .number_literal) declared = std.fmt.parseInt(u64, t.tokenSlice(t.nodeMainToken(field)), 10) catch 0;
        };
        if (declared != version and declared != legacy_version) return r.problem(decl.file, init, .unknown_version);
        if (r.version == 0) r.version = declared;
        if (r.version != declared) return r.problem(decl.file, init, .unknown_version);
        if (declared == version) return r.fields(decl.file, literal.ast.fields);
        for (literal.ast.fields) |field| {
            const name = fieldName(t, field);
            if (std.mem.eql(u8, name, "version")) continue;
            if (std.mem.eql(u8, name, "include")) {
                try r.includes(decl.file, field);
            } else if (std.mem.eql(u8, name, "replaces")) {
                r.part = .replaces;
                defer r.part = .roles;
                for (try r.list(decl.file, field) orelse continue) |entry| try r.replace(decl.file, entry);
            } else if (std.mem.eql(u8, name, "door")) {
                r.part = .replaces;
                defer r.part = .roles;
                for (try r.list(decl.file, field) orelse continue) |entry| try r.door.append(r.facts.gpa, .{ .reference = try r.reference(decl.file, entry, .own), .file = decl.file, .node = entry });
            } else if (std.mem.eql(u8, name, "deprecated")) {
                r.part = .deprecated;
                defer r.part = .roles;
                for (try r.list(decl.file, field) orelse continue) |entry| try r.deprecation(decl.file, entry);
            } else if (std.mem.eql(u8, name, "roles")) {
                for (try r.list(decl.file, field) orelse continue) |entry| try r.role(decl.file, entry);
            } else if (std.mem.eql(u8, name, "pairs")) {
                for (try r.list(decl.file, field) orelse continue) |entry| try r.pair(decl.file, entry);
            } else try r.problem(decl.file, field, .unknown_field);
        }
    }

    /// A version 2 `lint_rules`'s fields.
    fn fields(r: *Reader, file: Project.FileId, all: []const Ast.Node.Index) Error!void {
        for (all) |field| {
            const name = fieldName(r.tree(file), field);
            if (std.mem.eql(u8, name, "version")) continue;
            if (std.mem.eql(u8, name, "include")) {
                try r.includes(file, field);
                continue;
            }
            const part = std.meta.stringToEnum(enum { rules, governed, replaces }, name) orelse {
                try r.problem(file, field, .unknown_field);
                continue;
            };
            r.part = switch (part) {
                .rules => .rules,
                .governed => .governed,
                .replaces => .replaces,
            };
            defer r.part = .roles;
            for (try r.list(file, field) orelse continue) |entry| switch (part) {
                .rules => try r.declaredRule(file, entry),
                .governed => try r.governedType(file, entry),
                .replaces => try r.replacement(file, entry),
            };
        }
    }

    const RuleField = enum { id, name, kind, reads, default, purpose };

    /// `.{ .id = .A007, .name = "...", .kind = .ban, .reads = .replaces, .default = true,
    /// .purpose = "..." }`, every field once. An entry with a problem is not registered.
    fn declaredRule(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!void {
        const t = r.tree(file);
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = t.fullStructInit(&buffer, node) orelse return r.problem(file, node, .malformed);
        const before = r.problems.items.len;
        var entry: Declared = .{ .id = "", .name = "", .kind = .ban, .reads = .replaces, .default = false, .purpose = "", .file = file, .node = node };
        var given: std.EnumSet(RuleField) = .empty;
        for (literal.ast.fields) |field| {
            const which = std.meta.stringToEnum(RuleField, fieldName(t, field)) orelse {
                try r.problem(file, field, .unknown_field);
                continue;
            };
            if (given.contains(which)) {
                try r.problem(file, field, .malformed);
                continue;
            }
            given.insert(which);
            switch (which) {
                .id => entry.id = try r.enumLiteral(file, field),
                .name => entry.name = try r.string(file, field),
                .kind => entry.kind = (try r.choice(Declared.Kind, file, field)) orelse continue,
                .reads => entry.reads = (try r.choice(Declared.Reads, file, field)) orelse continue,
                .default => entry.default = (try r.boolean(file, field)) orelse continue,
                .purpose => entry.purpose = try r.string(file, field),
            }
        }
        if (given.count() != std.enums.values(RuleField).len) try r.problem(file, node, .malformed);
        if (r.problems.items.len != before) return;
        for (r.rule_table.items) |earlier| if (std.mem.eql(u8, earlier.id, entry.id)) return r.problem(file, node, .duplicate_rule);
        try r.rule_table.append(r.facts.gpa, entry);
    }

    /// `.{ .type = T, .internal = .{ .field, ... }, .exits = .{ .member, ... } }`, both lists
    /// optional (a type alone is governed for the cast and reflection ban): each name a member of
    /// every container `T` is, never a spelling at a use site.
    fn governedType(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!void {
        const t = r.tree(file);
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = t.fullStructInit(&buffer, node) orelse return r.problem(file, node, .malformed);
        var entry: Governance = .{ .type = .unresolved, .containers = &.{}, .internal = &.{}, .exits = &.{}, .file = file, .node = node };
        var type_node: ?Ast.Node.Index = null;
        var internal: ?Ast.Node.Index = null;
        var exits: ?Ast.Node.Index = null;
        for (literal.ast.fields) |field| {
            const name = fieldName(t, field);
            if (std.mem.eql(u8, name, "type")) {
                type_node = field;
            } else if (std.mem.eql(u8, name, "internal")) {
                internal = field;
            } else if (std.mem.eql(u8, name, "exits")) {
                exits = field;
            } else try r.problem(file, field, .unknown_field);
        }
        const written = type_node orelse return r.problem(file, node, .malformed);
        entry.type = try r.resolved(file, written, .own);
        if (entry.type.declaration()) |decl| {
            entry.containers = try r.containersOf(decl);
            if (entry.containers.len == 0) try r.problem(file, written, .malformed);
        }
        entry.internal = try r.namedMembers(file, internal, entry.containers, .field);
        entry.exits = try r.namedMembers(file, exits, entry.containers, .function);
        try r.governance.append(r.facts.gpa, entry);
    }

    /// Each enum literal of the list at `node` as a member of every one of `containers`, of the
    /// kind asked: a name one lacks is unresolved, one of another kind malformed.
    fn namedMembers(r: *Reader, file: Project.FileId, node: ?Ast.Node.Index, containers: []const Facts.Container, kind: enum { field, function }) Error![]const Facts.Decl {
        var found: std.ArrayList(Facts.Decl) = .empty;
        for (try r.list(file, node orelse return &.{}) orelse return &.{}) |each| {
            const raw = try r.enumLiteral(file, each);
            if (raw.len == 0) continue;
            const name = try r.facts.memberName(raw);
            for (containers) |container| {
                const decl = r.facts.member(container, name) orelse {
                    try r.problem(file, each, .unresolved);
                    break;
                };
                const record = r.facts.project.at(decl.file).model.declarations[@backingInt(decl.index)];
                const fits = switch (kind) {
                    .field => record.kind == .field,
                    .function => record.kind == .function,
                };
                if (!fits) {
                    try r.problem(file, each, .malformed);
                    break;
                }
                try found.append(r.facts.gpa, decl);
            }
        }
        return found.toOwnedSlice(r.facts.gpa);
    }

    /// The containers a type declaration is: the type itself, or each one a type function
    /// returns (`Facts.returnedContainers`), every part of a choice included. Empty where any
    /// part is none of these.
    fn containersOf(r: *Reader, decl: Facts.Decl) Error![]const Facts.Container {
        const value = try r.facts.declaration(decl);
        var found: std.ArrayList(Facts.Container) = .empty;
        for (Facts.valueParts(&value)) |part| switch (part) {
            .container, .instance => |c| try found.append(r.facts.gpa, .{ .file = c.file, .scope = c.scope }),
            .function => |function| {
                const returned = (try r.facts.template(function)) orelse return &.{};
                const made = try Facts.returnedContainers(r.facts.gpa, returned);
                if (made.len == 0) return &.{};
                for (made) |c| try found.append(r.facts.gpa, .{ .file = c.file, .scope = c.scope });
            },
            .alternatives => unreachable, // unreachable: valueParts gives no choice as a part
            else => return &.{},
        };
        return found.toOwnedSlice(r.facts.gpa);
    }

    /// `.{ .rule = .A0xx, <one target>, .held = .field, .with = D | .{ D, ... }, .why = "...",
    /// .door = .{ ... } }`; the target one of `.decl`, `.members` (with `.except`), `.field`,
    /// `.builtin` and `.symbol`.
    fn replacement(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!void {
        const t = r.tree(file);
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = t.fullStructInit(&buffer, node) orelse return r.problem(file, node, .malformed);
        var entry: Replacement = .{ .rule = "", .target = .unresolved, .file = file, .node = node };
        var rule_node: ?Ast.Node.Index = null;
        var targets: usize = 0;
        var members: ?Ast.Node.Index = null;
        var except: ?Ast.Node.Index = null;
        var held: ?Ast.Node.Index = null;
        for (literal.ast.fields) |field| {
            const name = fieldName(t, field);
            if (std.mem.eql(u8, name, "rule")) {
                entry.rule = try r.enumLiteral(file, field);
                rule_node = field;
            } else if (std.mem.eql(u8, name, "decl")) {
                targets += 1;
                entry.target = try r.declTarget(file, field);
            } else if (std.mem.eql(u8, name, "members")) {
                targets += 1;
                members = field;
            } else if (std.mem.eql(u8, name, "except")) {
                except = field;
            } else if (std.mem.eql(u8, name, "field")) {
                targets += 1;
                entry.target = try r.fieldTarget(file, field);
            } else if (std.mem.eql(u8, name, "builtin")) {
                targets += 1;
                entry.target = try r.builtinTarget(file, field);
            } else if (std.mem.eql(u8, name, "symbol")) {
                targets += 1;
                const symbol = try r.string(file, field);
                entry.target = if (symbol.len == 0) .unresolved else .{ .symbol = symbol };
            } else if (std.mem.eql(u8, name, "held")) {
                held = field;
            } else if (std.mem.eql(u8, name, "with")) {
                entry.with = try r.references(file, field);
            } else if (std.mem.eql(u8, name, "why")) {
                entry.why = try r.string(file, field);
            } else if (std.mem.eql(u8, name, "door")) {
                var doors: std.ArrayList(Reference) = .empty;
                for (try r.list(file, field) orelse continue) |each| try doors.append(r.facts.gpa, try r.resolved(file, each, .own));
                entry.door = try doors.toOwnedSlice(r.facts.gpa);
            } else try r.problem(file, field, .unknown_field);
        }
        // One target, the rule, an answer and why.
        if (targets != 1 or rule_node == null or entry.with.len == 0 or entry.why.len == 0) return r.problem(file, node, .malformed);
        if (members) |at| {
            entry.target = try r.membersTarget(file, at, except);
        } else if (except) |at| return r.problem(file, at, .malformed);
        if (held) |at| {
            const said = try r.enumLiteral(file, at);
            if (said.len == 0) return;
            if (!std.mem.eql(u8, said, "field") or entry.target != .decl) return r.problem(file, at, .malformed);
            entry.held = true;
        }
        try r.named_rules.append(r.facts.gpa, .{ .file = file, .node = rule_node.? });
        try r.replacements.append(r.facts.gpa, entry);
    }

    /// Each replacement's rule, once every `.rules` the root includes is read: one the package
    /// declares, to read `replaces`.
    fn settleRules(r: *Reader) Error!void {
        r.part = .replaces;
        defer r.part = .roles;
        for (r.replacements.items, r.named_rules.items) |entry, at| {
            for (r.rule_table.items) |declared| {
                if (std.mem.eql(u8, declared.id, entry.rule) and declared.reads == .replaces) break;
            } else try r.problem(at.file, at.node, .unknown_rule);
        }
    }

    /// `.decl = D`: a declaration of std's or the package's own, through aliases; a std member
    /// each target declares in a holder of its own, in each holder.
    fn declTarget(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!Replacement.Form {
        const found = try r.resolved(file, node, .std_or_own);
        return switch (found) {
            .decl => |one| .{ .decl = try r.facts.gpa.dupe(Facts.Decl, &.{one}) },
            .each_target => |all| .{ .decl = all },
            .unresolved, .foreign => .unresolved,
        };
    }

    /// `.members = C, .except = .{ D, ... }`: each function declared directly in `C`, so one a
    /// later Zig adds is in it; an exception that is no such function is unresolved.
    fn membersTarget(r: *Reader, file: Project.FileId, node: Ast.Node.Index, except: ?Ast.Node.Index) Error!Replacement.Form {
        const decl = (try r.resolved(file, node, .std_or_own)).declaration() orelse return .unresolved;
        const container = (try r.containerOf(decl)) orelse {
            try r.problem(file, node, .malformed);
            return .unresolved;
        };
        var all: std.ArrayList(Facts.Decl) = .empty;
        for (r.facts.project.at(container.file).model.declarations, 0..) |one, i| {
            if (one.kind == .function and one.scope == container.scope) try all.append(r.facts.gpa, .{ .file = container.file, .index = @fromBackingInt(@intCast(i)) });
        }
        for (try r.list(file, except orelse return .{ .members = all.items }) orelse &.{}) |each| {
            const left = (try r.resolved(file, each, .std_or_own)).declaration() orelse continue;
            for (all.items, 0..) |one, i| {
                if (std.meta.eql(one, left)) {
                    _ = all.orderedRemove(i);
                    break;
                }
            } else try r.problem(file, each, .unresolved);
        }
        return .{ .members = all.items };
    }

    /// `.field = .{ .type = T, .name = .f }`: the field `f` declares in `T`.
    fn fieldTarget(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!Replacement.Form {
        const t = r.tree(file);
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = t.fullStructInit(&buffer, node) orelse {
            try r.problem(file, node, .malformed);
            return .unresolved;
        };
        var holder: ?Ast.Node.Index = null;
        var name: ?Ast.Node.Index = null;
        for (literal.ast.fields) |field| {
            const given = fieldName(t, field);
            if (std.mem.eql(u8, given, "type")) {
                holder = field;
            } else if (std.mem.eql(u8, given, "name")) {
                name = field;
            } else try r.problem(file, field, .unknown_field);
        }
        if (holder == null or name == null) {
            try r.problem(file, node, .malformed);
            return .unresolved;
        }
        const raw = try r.enumLiteral(file, name.?);
        const decl = (try r.resolved(file, holder.?, .std_or_own)).declaration() orelse return .unresolved;
        if (raw.len == 0) return .unresolved;
        const container = (try r.containerOf(decl)) orelse {
            try r.problem(file, holder.?, .malformed);
            return .unresolved;
        };
        const found = r.facts.member(container, try r.facts.memberName(raw)) orelse {
            try r.problem(file, name.?, .unresolved);
            return .unresolved;
        };
        if (r.facts.project.at(found.file).model.declarations[@backingInt(found.index)].kind != .field) {
            try r.problem(file, name.?, .malformed);
            return .unresolved;
        }
        return .{ .field = found };
    }

    /// `.builtin = .@"@name"`: one the language has (`std.zig.BuiltinFn.list`).
    fn builtinTarget(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!Replacement.Form {
        const raw = try r.enumLiteral(file, node);
        if (raw.len == 0) return .unresolved;
        const name = try r.facts.memberName(raw);
        if (!std.zig.BuiltinFn.list.has(name)) {
            try r.problem(file, node, .unknown_builtin);
            return .unresolved;
        }
        return .{ .builtin = name };
    }

    /// `.with = D` or `.with = .{ D, ... }`: the package's answers.
    fn references(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error![]const Reference {
        var buffer: [2]Ast.Node.Index = undefined;
        const array = r.tree(file).fullArrayInit(&buffer, node) orelse return r.facts.gpa.dupe(Reference, &.{try r.resolved(file, node, .own)});
        var found: std.ArrayList(Reference) = .empty;
        for (array.ast.elements) |each| try found.append(r.facts.gpa, try r.resolved(file, each, .own));
        return found.toOwnedSlice(r.facts.gpa);
    }

    /// A reference (`reference`) through declaration aliases to the declaration it ends at
    /// (`Facts.origin`): one a cycle or a computed alias leaves unknown is unresolved.
    fn resolved(r: *Reader, file: Project.FileId, node: Ast.Node.Index, whose: Whose) Error!Reference {
        const found = try r.reference(file, node, whose);
        switch (found) {
            .decl => |decl| return .{ .decl = (try r.originOf(file, node, decl)) orelse return .unresolved },
            .each_target => |all| {
                const ends = try r.facts.gpa.alloc(Facts.Decl, all.len);
                for (all, ends) |one, *end| end.* = (try r.originOf(file, node, one)) orelse return .unresolved;
                return .{ .each_target = ends };
            },
            .unresolved, .foreign => return found,
        }
    }

    fn originOf(r: *Reader, file: Project.FileId, node: Ast.Node.Index, decl: Facts.Decl) Error!?Facts.Decl {
        return switch (try r.facts.origin(decl)) {
            .decl => |end| end,
            .none, .unknown => {
                try r.problem(file, node, .unresolved);
                return null;
            },
        };
    }

    /// An enum literal naming one of `E`'s tags; null, a problem, for anything else.
    fn choice(r: *Reader, comptime E: type, file: Project.FileId, node: Ast.Node.Index) Error!?E {
        const name = try r.enumLiteral(file, node);
        if (name.len == 0) return null;
        return std.meta.stringToEnum(E, name) orelse {
            try r.problem(file, node, .malformed);
            return null;
        };
    }

    /// `true` or `false`; null, a problem, for anything else.
    fn boolean(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!?bool {
        const t = r.tree(file);
        if (t.nodeTag(node) == .identifier) {
            const name = t.tokenSlice(t.nodeMainToken(node));
            if (std.mem.eql(u8, name, "true")) return true;
            if (std.mem.eql(u8, name, "false")) return false;
        }
        try r.problem(file, node, .malformed);
        return null;
    }

    /// `.include = .{ sync.lint_rules, ... }`: each by its declaration.
    fn includes(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!void {
        for (try r.list(file, node) orelse return) |each| switch (try r.facts.definition(file, each)) {
            .decl => |decl| {
                const named = r.facts.project.at(decl.file).model.declarations[@backingInt(decl.index)];
                if (!std.mem.eql(u8, named.name, "lint_rules")) {
                    try r.problem(file, each, .malformed);
                    continue;
                }
                if (!Identity.of(r.facts.project, decl.file).eql(r.package)) {
                    try r.problem(file, each, .foreign);
                    continue;
                }
                try r.declaration(decl);
            },
            .none, .unknown => try r.problem(file, each, .unresolved),
        };
    }

    fn replace(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!void {
        var entry: Replace = .{ .with = .unresolved, .why = "" };
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = r.tree(file).fullStructInit(&buffer, node) orelse return r.problem(file, node, .malformed);
        for (literal.ast.fields) |field| {
            const name = fieldName(r.tree(file), field);
            if (std.mem.eql(u8, name, "std")) {
                entry.std = try r.reference(file, field, .std);
            } else if (std.mem.eql(u8, name, "symbol")) {
                entry.symbol = try r.string(file, field);
            } else if (std.mem.eql(u8, name, "with")) {
                entry.with = try r.reference(file, field, .own);
            } else if (std.mem.eql(u8, name, "why")) {
                entry.why = try r.string(file, field);
            } else try r.problem(file, field, .unknown_field);
        }
        // One of a std declaration and an external symbol, never both or neither.
        if ((entry.std == null) == (entry.symbol == null)) return r.problem(file, node, .malformed);
        try r.replaces.append(r.facts.gpa, entry);
    }

    fn deprecation(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!void {
        var entry: Deprecated = .{ .decl = .unresolved, .with = null, .why = "" };
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = r.tree(file).fullStructInit(&buffer, node) orelse return r.problem(file, node, .malformed);
        for (literal.ast.fields) |field| {
            const name = fieldName(r.tree(file), field);
            if (std.mem.eql(u8, name, "decl")) {
                entry.decl = try r.reference(file, field, .own);
            } else if (std.mem.eql(u8, name, "with")) {
                entry.with = if (r.tree(file).nodeTag(field) == .identifier and std.mem.eql(u8, r.tree(file).tokenSlice(r.tree(file).nodeMainToken(field)), "null")) null else try r.reference(file, field, .own);
            } else if (std.mem.eql(u8, name, "why")) {
                entry.why = try r.string(file, field);
            } else try r.problem(file, field, .unknown_field);
        }
        try r.deprecated.append(r.facts.gpa, entry);
    }

    fn role(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!void {
        var entry: Role = .{ .type = .unresolved, .role = "", .internal = &.{} };
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = r.tree(file).fullStructInit(&buffer, node) orelse return r.problem(file, node, .malformed);
        for (literal.ast.fields) |field| {
            const name = fieldName(r.tree(file), field);
            if (std.mem.eql(u8, name, "type")) {
                entry.type = try r.reference(file, field, .own);
            } else if (std.mem.eql(u8, name, "role")) {
                entry.role = try r.enumLiteral(file, field);
                if (r.facts.role_names) |known| {
                    for (known) |each| {
                        if (std.mem.eql(u8, each, entry.role)) break;
                    } else try r.problem(file, field, .unknown_role);
                }
            } else if (std.mem.eql(u8, name, "internal")) {
                var names: std.ArrayList([]const u8) = .empty;
                for (try r.list(file, field) orelse continue) |each| try names.append(r.facts.gpa, try r.enumLiteral(file, each));
                entry.internal = try names.toOwnedSlice(r.facts.gpa);
            } else try r.problem(file, field, .unknown_field);
        }
        try r.roles.append(r.facts.gpa, entry);
    }

    fn pair(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!void {
        var entry: Pair = .{ .file = file, .node = node };
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = r.tree(file).fullStructInit(&buffer, node) orelse return r.problem(file, node, .malformed);
        // The type first, wherever it is written: the operations are its members.
        var owing: ?Facts.Container = null;
        for (literal.ast.fields) |field| if (std.mem.eql(u8, fieldName(r.tree(file), field), "type")) {
            entry.type = try r.reference(file, field, .own);
            if (entry.type.?.declaration()) |decl| owing = try r.containerOf(decl);
            if (owing == null and entry.type.? == .decl) try r.problem(file, field, .unresolved);
        };
        for (literal.ast.fields) |field| {
            const name = fieldName(r.tree(file), field);
            if (std.mem.eql(u8, name, "type")) continue;
            if (std.mem.eql(u8, name, "acquire")) {
                entry.acquire = try r.reference(file, field, .own);
                continue;
            }
            if (std.mem.eql(u8, name, "transfer")) {
                var moves: std.ArrayList(Transfer) = .empty;
                for (try r.list(file, field) orelse continue) |one| try moves.append(r.facts.gpa, .{ .member = try r.operation(file, one, owing) });
                entry.transfer = try moves.toOwnedSlice(r.facts.gpa);
                continue;
            }
            const operations: *[]const Reference = if (std.mem.eql(u8, name, "release"))
                &entry.release
            else if (std.mem.eql(u8, name, "teardown"))
                &entry.teardown
            else {
                try r.problem(file, field, .unknown_field);
                continue;
            };
            var each: std.ArrayList(Reference) = .empty;
            for (try r.list(file, field) orelse continue) |one| try each.append(r.facts.gpa, try r.operation(file, one, owing));
            operations.* = try each.toOwnedSlice(r.facts.gpa);
        }
        try r.pairs.append(r.facts.gpa, entry);
    }

    /// Settles each pair once every pair is read: where each transfer goes, and the pairs refused.
    fn settlePairs(r: *Reader) Error!void {
        var owing: std.ArrayList(Facts.Container) = .empty;
        for (r.pairs.items) |each| {
            const decl = (each.type orelse continue).declaration() orelse continue;
            try owing.append(r.facts.gpa, (try r.containerOf(decl)) orelse continue);
        }
        for (r.pairs.items) |*each| {
            var refused = each.teardown.len != 0 and each.release.len == 0;
            for ([_][]const Reference{ each.release, each.teardown }) |operations| for (operations) |named| {
                if (named.declaration()) |decl| if (try r.facts.declaration(decl) != .function) {
                    refused = true;
                };
            };
            const moves = try r.facts.gpa.dupe(Transfer, each.transfer);
            for (moves) |*move| {
                const decl = move.member.declaration() orelse continue;
                move.to = (try r.destination(decl, owing.items)) orelse {
                    refused = true;
                    continue;
                };
            }
            if (refused) {
                for (moves) |*move| move.to = .unknown;
                each.refused = true;
                try r.problem(each.file, each.node, .refused);
            }
            each.transfer = moves;
        }
    }

    /// Where the function `decl` moves an obligation: its result where its declared result
    /// (through `!` and `?`) is an owing type; else the one parameter, the receiver aside, that
    /// points to an owing type. Null where neither settles it.
    fn destination(r: *Reader, decl: Facts.Decl, owing: []const Facts.Container) Error!?@FieldType(Transfer, "to") {
        if (try r.facts.declaration(decl) != .function) return null;
        const t = r.tree(decl.file);
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = t.fullFnProto(&buffer, r.facts.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return null;
        if (proto.ast.return_type.unwrap()) |result| {
            // A result that may or may not be an owing type does not settle it.
            switch (owes(try r.facts.resolve(decl.file, result), owing, false) orelse return null) {
                true => return .result,
                false => {},
            }
        }
        var found: ?usize = null;
        var it = proto.iterate(t);
        var position: usize = 0;
        while (it.next()) |param| : (position += 1) {
            const written = param.type_expr orelse continue;
            if (position == 0) continue; // The receiver is the value the obligation leaves.
            if (!(owes(try r.facts.resolve(decl.file, written), owing, true) orelse return null)) continue;
            if (found != null) return null;
            found = position;
        }
        return if (found) |at| .{ .argument = at } else null;
    }

    /// The container a type declaration names: the type itself, or the one a type function
    /// returns, where every part of a choice names that one. Null where it resolves to neither,
    /// or a choice names different ones.
    fn containerOf(r: *Reader, decl: Facts.Decl) Error!?Facts.Container {
        const value = try r.facts.declaration(decl);
        var found: ?Facts.Container = null;
        for (Facts.valueParts(&value)) |part| {
            const one = switch (part) {
                .container, .instance => |c| c,
                .function => |function| try r.templateContainer(function) orelse return null,
                .alternatives => unreachable, // unreachable: valueParts gives no choice as a part
                else => return null,
            };
            if (found) |earlier| if (earlier.file != one.file or earlier.scope != one.scope) return null;
            found = one;
        }
        return found;
    }

    /// The one container the type function `function` returns, where every part of a choice of
    /// templates is that one; null otherwise.
    fn templateContainer(r: *Reader, function: Facts.Decl) Error!?Facts.Container {
        const returned = (try r.facts.template(function)) orelse return null;
        var found: ?Facts.Container = null;
        for (Facts.valueParts(&returned)) |part| {
            const one = switch (part) {
                .container, .instance => |c| c,
                .alternatives => unreachable, // unreachable: valueParts gives no choice as a part
                else => return null,
            };
            if (found) |earlier| if (earlier.file != one.file or earlier.scope != one.scope) return null;
            found = one;
        }
        return found;
    }

    /// An operation of a pair: a member of the owing type written as an enum literal (`.deinit`),
    /// resolved in its container, or a reference.
    fn operation(r: *Reader, file: Project.FileId, node: Ast.Node.Index, owing: ?Facts.Container) Error!Reference {
        if (r.tree(file).nodeTag(node) != .enum_literal) return r.reference(file, node, .own);
        const container = owing orelse {
            try r.problem(file, node, .unresolved);
            return .unresolved;
        };
        const found = r.facts.member(container, try r.enumLiteral(file, node)) orelse {
            try r.problem(file, node, .unresolved);
            return .unresolved;
        };
        return .{ .decl = found };
    }

    /// A reference: an expression naming a declaration, or `.{ .generic = F, .member = .m }`,
    /// the member `m` of the container the type function `F` returns, resolved there once.
    /// `.std` must name one of std's; any other, one of the declaring package's.
    fn reference(r: *Reader, file: Project.FileId, node: Ast.Node.Index, whose: Whose) Error!Reference {
        if (whose != .own) if (try r.targetMember(file, node, whose)) |each| return each;
        const found: Facts.Decl = switch (try r.generic(file, node)) {
            .decl => |decl| decl,
            .unresolved => {
                try r.problem(file, node, .unresolved);
                return .unresolved;
            },
            .not => switch (try r.facts.definition(file, node)) {
                .decl => |decl| decl,
                .none, .unknown => {
                    try r.problem(file, node, .unresolved);
                    return .unresolved;
                },
            },
        };
        if (!try r.belongs(found, whose)) {
            try r.problem(file, node, .foreign);
            return .{ .foreign = found };
        }
        return .{ .decl = found };
    }

    /// Whose declarations a reference may name: std's, the declaring package's, or either.
    const Whose = enum { std, own, std_or_own };

    fn belongs(r: *Reader, decl: Facts.Decl, whose: Whose) Error!bool {
        const own = Identity.of(r.facts.project, decl.file).eql(r.package);
        return switch (whose) {
            .std => try r.facts.standard(decl.file),
            .own => own,
            .std_or_own => own or try r.facts.standard(decl.file),
        };
    }

    /// What `node` names where it is a member of a choice of holders, as std's per-target
    /// constants are: the name's declaration in each part that declares it. A target whose
    /// holder has no such name (`void`, a struct without it) has nothing to replace; a part that
    /// does not resolve, or a name no part declares, leaves it unresolved. Null where `node` is
    /// no member of a choice.
    fn targetMember(r: *Reader, file: Project.FileId, node: Ast.Node.Index, whose: Whose) Error!?Reference {
        const t = r.tree(file);
        if (Facts.accesses.formOf(t.nodeTag(node)) != .member) return null;
        const holder_node, const name_token = t.nodeData(node).node_and_token;
        const holder = try r.facts.resolve(file, holder_node);
        if (holder != .alternatives) return null;
        const name = try r.facts.memberName(t.tokenSlice(name_token));
        var found: std.ArrayList(Facts.Decl) = .empty;
        for (Facts.valueParts(&holder)) |part| switch (part) {
            .container, .instance => |container| if (r.facts.member(container, name)) |decl| {
                if (!try r.belongs(decl, whose)) {
                    try r.problem(file, node, .foreign);
                    return .{ .foreign = decl };
                }
                for (found.items) |known| {
                    if (std.meta.eql(known, decl)) break;
                } else try found.append(r.facts.gpa, decl);
            },
            .unknown => {
                try r.problem(file, node, .unresolved);
                return .unresolved;
            },
            .alternatives => unreachable, // unreachable: valueParts gives no choice as a part
            else => {},
        };
        if (found.items.len == 0) {
            try r.problem(file, node, .unresolved);
            return .unresolved;
        }
        return .{ .each_target = found.items };
    }

    /// What a `.{ .generic = F, .member = .m }` names: the member `m` of the container the type
    /// function `F` returns; `.not` where `node` is no such literal.
    fn generic(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!union(enum) { not, decl: Facts.Decl, unresolved } {
        const t = r.tree(file);
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = t.fullStructInit(&buffer, node) orelse return .not;
        var function: ?Ast.Node.Index = null;
        var member: ?[]const u8 = null;
        for (literal.ast.fields) |field| {
            const name = fieldName(t, field);
            if (std.mem.eql(u8, name, "generic")) {
                function = field;
            } else if (std.mem.eql(u8, name, "member") and t.nodeTag(field) == .enum_literal) {
                member = t.tokenSlice(t.nodeMainToken(field));
            } else return .not;
        }
        const named = switch (try r.facts.definition(file, function orelse return .not)) {
            .decl => |decl| decl,
            .none, .unknown => return .unresolved,
        };
        // Through aliases to the type function (`pub const Guarded = sync.Guarded;`).
        const made_by = switch (try r.facts.origin(named)) {
            .decl => |decl| decl,
            .none, .unknown => return .unresolved,
        };
        const container = switch ((try r.facts.template(made_by)) orelse return .unresolved) {
            .container, .instance => |c| c,
            // A template chosen per build is no one container to read a member of.
            .alternatives => return .unresolved,
            else => return .unresolved,
        };
        return if (r.facts.member(container, member orelse return .not)) |decl| .{ .decl = decl } else .unresolved;
    }

    /// The elements of a list literal (`.{ a, b }`, `.{}`), or null, a problem, for anything else.
    fn list(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!?[]const Ast.Node.Index {
        const t = r.tree(file);
        var buffer: [2]Ast.Node.Index = undefined;
        if (t.fullArrayInit(&buffer, node)) |array| return try r.facts.gpa.dupe(Ast.Node.Index, array.ast.elements);
        if (t.fullStructInit(&buffer, node)) |empty| if (empty.ast.fields.len == 0) return &.{};
        try r.problem(file, node, .malformed);
        return null;
    }

    fn string(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error![]const u8 {
        const t = r.tree(file);
        if (t.nodeTag(node) != .string_literal) {
            try r.problem(file, node, .malformed);
            return "";
        }
        const quoted = t.tokenSlice(t.nodeMainToken(node));
        return quoted[1 .. quoted.len - 1];
    }

    fn enumLiteral(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error![]const u8 {
        const t = r.tree(file);
        if (t.nodeTag(node) != .enum_literal) {
            try r.problem(file, node, .malformed);
            return "";
        }
        return t.tokenSlice(t.nodeMainToken(node));
    }
};

/// The name a struct literal's field initializer is given: `.name = value`.
fn fieldName(t: *const Ast, init: Ast.Node.Index) []const u8 {
    return t.tokenSlice(t.firstToken(init) - 2);
}

const Fixture = struct {
    project: Project,
    arena: std.heap.ArenaAllocator,
    facts: Facts,

    fn init(f: *Fixture, inputs: []const Project.Input, imports: []const Project.Import) !void {
        f.project = try Project.init(std.testing.allocator, inputs, imports, .{});
        f.arena = .init(std.testing.allocator);
        f.facts = .{ .project = &f.project, .gpa = f.arena.allocator() };
    }

    fn deinit(f: *Fixture) void {
        f.facts.deinit();
        f.arena.deinit();
        f.project.deinit();
    }

    fn name(f: *Fixture, reference: Reference) []const u8 {
        return f.declName(reference.declaration() orelse return "");
    }

    fn declName(f: *Fixture, decl: Facts.Decl) []const u8 {
        return f.project.at(decl.file).model.declarations[@backingInt(decl.index)].name;
    }
};

const fake_std_v2 =
    \\pub const Io = struct {
    \\    pub const Mutex = struct { state: u32 };
    \\    pub const Reader = struct {
    \\        buffer: []u8,
    \\        pub fn fixed() void {}
    \\        pub fn take() void {}
    \\        pub fn peek() void {}
    \\    };
    \\};
    \\
;

test "a version 2 root is read by declaration: its rules, a type function governed in its instances, and each replacement's target, answers and door, an include's entries first" {
    var f: Fixture = undefined;
    try f.init(&.{
        .{ .name = "pkg/root.zig", .package = "pkg", .fingerprint = 7, .bytes =
        \\const std = @import("std");
        \\const own = @import("own.zig");
        \\pub fn Guarded(comptime T: type) type {
        \\    return struct {
        \\        value: T,
        \\        pub fn acquire(g: *@This()) void {
        \\            _ = g;
        \\        }
        \\        pub fn raw(g: *@This()) T {
        \\            return g.value;
        \\        }
        \\    };
        \\}
        \\pub const Atomic = struct { cell: u32 };
        \\pub fn syncFile() void {}
        \\pub const lint_rules = .{
        \\    .version = 2,
        \\    .include = .{own.lint_rules},
        \\    .rules = .{
        \\        .{ .id = .X001, .name = "governed", .kind = .ban, .reads = .governed, .default = true, .purpose = "internal fields" },
        \\        .{ .id = .X002, .name = "replaced", .kind = .ban, .reads = .replaces, .default = false, .purpose = "std's raw forms" },
        \\    },
        \\    .governed = .{.{ .type = Guarded, .internal = .{.value}, .exits = .{.raw} }},
        \\    .replaces = .{
        \\        .{ .rule = .X002, .decl = std.Io.Mutex, .held = .field, .with = .{ Atomic, .{ .generic = Guarded, .member = .acquire } }, .why = "a lock with its data" },
        \\        .{ .rule = .X002, .members = std.Io.Reader, .except = .{std.Io.Reader.fixed}, .with = own.readUntrusted, .why = "input", .door = .{syncFile} },
        \\        .{ .rule = .X002, .field = .{ .type = std.Io.Reader, .name = .buffer }, .with = own.readUntrusted, .why = "input" },
        \\        .{ .rule = .X002, .builtin = .@"@atomicLoad", .with = Atomic, .why = "one cell" },
        \\        .{ .rule = .X002, .symbol = "fsync", .with = syncFile, .why = "durable" },
        \\    },
        \\};
        },
        .{ .name = "pkg/own.zig", .package = "pkg", .fingerprint = 7, .bytes =
        \\pub fn readFile() void {}
        \\pub fn readUntrusted() void {}
        \\pub const lint_rules = .{ .version = 2, .replaces = .{.{ .rule = .X002, .decl = readFile, .with = readUntrusted, .why = "its result is input" }} };
        },
        .{ .name = "std", .bytes = fake_std_v2, .selected = false },
    }, &.{
        .{ .from = 0, .spelling = "std", .target = 2 },
        .{ .from = 0, .spelling = "own.zig", .target = 1 },
    });
    defer f.deinit();
    const rules = try of(&f.facts, f.project.sources[0].id);
    try std.testing.expectEqual(@as(usize, 0), rules.problems.len);
    try std.testing.expectEqual(version, rules.version);
    try std.testing.expectEqual(@as(usize, 2), rules.rule_table.len);
    try std.testing.expectEqualStrings("X001", rules.rule_table[0].id);
    try std.testing.expectEqual(Declared.Reads.governed, rules.rule_table[0].reads);
    try std.testing.expect(rules.rule_table[0].default and !rules.rule_table[1].default);
    // The type function's instances: the container it returns, its members found there.
    try std.testing.expectEqual(@as(usize, 1), rules.governance.len);
    try std.testing.expectEqual(@as(usize, 1), rules.governance[0].containers.len);
    try std.testing.expectEqualStrings("value", f.declName(rules.governance[0].internal[0]));
    try std.testing.expectEqualStrings("raw", f.declName(rules.governance[0].exits[0]));
    // The include's entry first, its rule declared by the root.
    try std.testing.expectEqual(@as(usize, 6), rules.replacements.len);
    try std.testing.expectEqualStrings("readFile", f.declName(rules.replacements[0].declarations()[0]));
    const mutex = rules.replacements[1];
    try std.testing.expectEqualStrings("Mutex", f.declName(mutex.declarations()[0]));
    try std.testing.expect(mutex.held and mutex.door == null);
    try std.testing.expectEqualStrings("acquire", f.name(mutex.with[1]));
    // Every function declared in the container, less the exception.
    const reads = rules.replacements[2].declarations();
    try std.testing.expectEqual(@as(usize, 2), reads.len);
    try std.testing.expectEqualStrings("take", f.declName(reads[0]));
    try std.testing.expectEqualStrings("peek", f.declName(reads[1]));
    try std.testing.expectEqualStrings("syncFile", f.name(rules.replacements[2].door.?[0]));
    try std.testing.expectEqualStrings("buffer", f.declName(rules.replacements[3].target.field));
    try std.testing.expectEqualStrings("@atomicLoad", rules.replacements[4].target.builtin);
    try std.testing.expectEqualStrings("fsync", rules.replacements[5].target.symbol);
}

test "what a version 2 root cannot name is a problem where it is written, one each" {
    const head =
        \\const std = @import("std");
        \\pub const T = struct {
        \\    f: u8,
        \\    pub fn m() void {}
        \\};
        \\pub fn answer() void {}
        \\
    ;
    const replaced = ".{ .id = .X002, .name = \"r\", .kind = .ban, .reads = .replaces, .default = true, .purpose = \"p\" }";
    const governed = ".{ .id = .X001, .name = \"g\", .kind = .ban, .reads = .governed, .default = true, .purpose = \"p\" }";
    for ([_]struct { []const u8, Problem.Why }{
        .{ ".rules = .{" ++ replaced ++ "}, .replaces = .{.{ .rule = .X009, .decl = std.Io.Mutex, .with = answer, .why = \"w\" }}", .unknown_rule },
        .{ ".rules = .{ " ++ replaced ++ ", " ++ governed ++ " }, .replaces = .{.{ .rule = .X001, .decl = std.Io.Mutex, .with = answer, .why = \"w\" }}", .unknown_rule },
        .{ ".rules = .{ " ++ replaced ++ ", " ++ replaced ++ " }", .duplicate_rule },
        .{ ".rules = .{.{ .id = .X003, .name = \"r\", .kind = .proof, .reads = .replaces, .default = true, .purpose = \"p\" }}", .malformed },
        .{ ".rules = .{.{ .id = .X003, .name = \"r\", .kind = .ban, .reads = .replaces, .purpose = \"p\" }}", .malformed },
        .{ ".rules = .{" ++ replaced ++ "}, .replaces = .{.{ .rule = .X002, .builtin = .@\"@notABuiltin\", .with = answer, .why = \"w\" }}", .unknown_builtin },
        .{ ".rules = .{" ++ replaced ++ "}, .replaces = .{.{ .rule = .X002, .decl = std.Io.Mutex, .symbol = \"x\", .with = answer, .why = \"w\" }}", .malformed },
        .{ ".rules = .{" ++ replaced ++ "}, .replaces = .{.{ .rule = .X002, .members = std.Io.Reader, .except = .{std.Io.Mutex}, .with = answer, .why = \"w\" }}", .unresolved },
        .{ ".rules = .{" ++ replaced ++ "}, .replaces = .{.{ .rule = .X002, .decl = std.Io.Mutex, .except = .{std.Io.Mutex}, .with = answer, .why = \"w\" }}", .malformed },
        .{ ".rules = .{" ++ replaced ++ "}, .replaces = .{.{ .rule = .X002, .builtin = .@\"@atomicLoad\", .held = .field, .with = answer, .why = \"w\" }}", .malformed },
        .{ ".rules = .{" ++ replaced ++ "}, .replaces = .{.{ .rule = .X002, .decl = std.Io.Mutex, .with = answer }}", .malformed },
        .{ ".rules = .{" ++ replaced ++ "}, .replaces = .{.{ .rule = .X002, .field = .{ .type = std.Io.Reader, .name = .take }, .with = answer, .why = \"w\" }}", .malformed },
        .{ ".governed = .{.{ .type = T, .internal = .{.g} }}", .unresolved },
        .{ ".governed = .{.{ .type = T, .exits = .{.f} }}", .malformed },
        .{ ".governed = .{.{ .internal = .{.f} }}", .malformed },
        .{ ".governed = .{.{ .type = std.Io.Mutex, .internal = .{.state} }}", .foreign },
        .{ ".roles = .{}", .unknown_field },
    }) |case| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ head, "pub const lint_rules = .{ .version = 2, ", case[0], " };\n" });
        defer std.testing.allocator.free(source);
        var f: Fixture = undefined;
        try f.init(&.{
            .{ .name = "pkg/root.zig", .package = "pkg", .fingerprint = 7, .bytes = source },
            .{ .name = "std", .bytes = fake_std_v2, .selected = false },
        }, &.{.{ .from = 0, .spelling = "std", .target = 1 }});
        defer f.deinit();
        const rules = try of(&f.facts, f.project.sources[0].id);
        std.testing.expectEqual(@as(usize, 1), rules.problems.len) catch |err| {
            std.debug.print("case: {s}\n", .{case[0]});
            return err;
        };
        try std.testing.expectEqual(case[1], rules.problems[0].why);
    }
}

test "an include of another version than its root's is not read" {
    var f: Fixture = undefined;
    try f.init(&.{
        .{ .name = "pkg/root.zig", .package = "pkg", .fingerprint = 7, .bytes = "const old = @import(\"old.zig\");\npub const lint_rules = .{ .version = 2, .include = .{old.lint_rules} };\n" },
        .{ .name = "pkg/old.zig", .package = "pkg", .fingerprint = 7, .bytes = "pub const Once = struct {};\npub const lint_rules = .{ .version = 1, .roles = .{.{ .type = Once, .role = .once }} };\n" },
    }, &.{.{ .from = 0, .spelling = "old.zig", .target = 1 }});
    defer f.deinit();
    const rules = try of(&f.facts, f.project.sources[0].id);
    try std.testing.expectEqual(@as(usize, 1), rules.problems.len);
    try std.testing.expectEqual(Problem.Why.unknown_version, rules.problems[0].why);
    try std.testing.expectEqual(@as(usize, 0), rules.roles.len);
}

const fake_std = "pub const Io = struct {\n    pub const Dir = struct {\n        pub fn createFileAtomic() void {}\n    };\n};\n";

test "a root's lint_rules are read by declaration: std's replaced, the package's own deprecated, roles, a generic's member as a pair, and an include cycle read once" {
    var f: Fixture = undefined;
    try f.init(&.{
        .{ .name = "consumer", .bytes = "const pkg = @import(\"pkg\");\npub fn f() void {\n    _ = pkg;\n}\n" },
        .{ .name = "pkg/root.zig", .package = "pkg", .fingerprint = 7, .selected = false, .bytes =
        \\const std = @import("std");
        \\const sync = @import("sync.zig");
        \\pub const Pending = struct {
        \\    pub fn publish() void {}
        \\    pub fn old() void {}
        \\};
        \\pub fn Guarded(comptime T: type) type {
        \\    return struct {
        \\        value: T,
        \\        pub fn acquire(g: *@This()) void {
        \\            _ = g;
        \\        }
        \\    };
        \\}
        \\pub const Secret = struct { data: u8 };
        \\pub const lint_rules = .{
        \\    .version = 1,
        \\    .include = .{sync.lint_rules},
        \\    .replaces = .{.{ .std = std.Io.Dir.createFileAtomic, .with = Pending.publish, .why = "airlock's publish is durable" }},
        \\    .deprecated = .{.{ .decl = Pending.old, .with = Pending.publish, .why = "renamed" }},
        \\    .roles = .{.{ .type = Secret, .role = .secret, .internal = .{.data} }},
        \\    .pairs = .{.{ .acquire = .{ .generic = Guarded, .member = .acquire }, .release = .{Pending.publish} }},
        \\};
        },
        .{ .name = "pkg/sync.zig", .package = "pkg", .fingerprint = 7, .selected = false, .bytes =
        \\const root = @import("root.zig");
        \\pub const Once = struct {};
        \\pub const lint_rules = .{ .version = 1, .include = .{root.lint_rules}, .roles = .{.{ .type = Once, .role = .once }} };
        },
        .{ .name = "std", .bytes = fake_std, .selected = false },
    }, &.{
        .{ .from = 0, .spelling = "pkg", .target = 1 },
        .{ .from = 1, .spelling = "std", .target = 3 },
        .{ .from = 1, .spelling = "sync.zig", .target = 2 },
        .{ .from = 2, .spelling = "root.zig", .target = 1 },
    });
    defer f.deinit();
    try std.testing.expectEqualSlices(Project.FileId, &.{ f.project.sources[1].id, f.project.sources[3].id }, try roots(&f.facts));
    const rules = try of(&f.facts, f.project.sources[1].id);
    try std.testing.expectEqual(@as(usize, 0), rules.problems.len);
    try std.testing.expectEqual(@as(usize, 1), rules.replaces.len);
    try std.testing.expectEqualStrings("createFileAtomic", f.name(rules.replaces[0].std.?));
    try std.testing.expectEqualStrings("publish", f.name(rules.replaces[0].with));
    try std.testing.expectEqualStrings("airlock's publish is durable", rules.replaces[0].why);
    try std.testing.expectEqualStrings("old", f.name(rules.deprecated[0].decl));
    // The root's own role, then the included one; the include back to the root reads nothing again.
    try std.testing.expectEqual(@as(usize, 2), rules.roles.len);
    try std.testing.expectEqualStrings("Once", f.name(rules.roles[0].type));
    try std.testing.expectEqualStrings("Secret", f.name(rules.roles[1].type));
    try std.testing.expectEqualStrings("secret", rules.roles[1].role);
    try std.testing.expectEqualStrings("data", rules.roles[1].internal[0]);
    try std.testing.expectEqualStrings("acquire", f.name(rules.pairs[0].acquire.?));
    try std.testing.expectEqualStrings("publish", f.name(rules.pairs[0].release[0]));
    // Read once for the run.
    try std.testing.expectEqual(rules, try of(&f.facts, f.project.sources[1].id));
}

test "what a root's lint_rules cannot name is a problem where it is written: drift, another package's declaration, a field the vocabulary lacks, another version" {
    var f: Fixture = undefined;
    try f.init(&.{
        .{ .name = "pkg/root.zig", .package = "pkg", .fingerprint = 7, .bytes =
        \\const other = @import("other");
        \\const Ns = struct {};
        \\pub fn publish() void {}
        \\pub const lint_rules = .{
        \\    .version = 1,
        \\    .deprecated = .{ .{ .decl = Ns.gone, .with = publish, .why = "gone" }, .{ .decl = other.thing, .with = null, .why = "not ours" } },
        \\    .colour = .red,
        \\};
        },
        .{ .name = "other/root.zig", .package = "other", .fingerprint = 9, .selected = false, .bytes = "pub fn thing() void {}\n" },
        .{ .name = "next/root.zig", .package = "next", .fingerprint = 3, .selected = false, .bytes = "pub fn thing() void {}\npub const lint_rules = .{ .version = 3, .deprecated = .{.{ .decl = thing, .why = \"later\" }} };\n" },
    }, &.{.{ .from = 0, .spelling = "other", .target = 1 }});
    defer f.deinit();
    const rules = try of(&f.facts, f.project.sources[0].id);
    var whys: [3]Problem.Why = undefined;
    for (rules.problems, 0..) |problem, i| whys[i] = problem.why;
    try std.testing.expectEqualSlices(Problem.Why, &.{ .unresolved, .foreign, .unknown_field }, whys[0..rules.problems.len]);
    try std.testing.expect(rules.deprecated[0].decl == .unresolved);
    try std.testing.expectEqualStrings("publish", f.name(rules.deprecated[0].with.?));
    try std.testing.expect(rules.deprecated[1].decl == .foreign);
    try std.testing.expectEqual(null, rules.deprecated[1].with);
    // Another version is read as no rules at all.
    const later = try of(&f.facts, f.project.sources[2].id);
    try std.testing.expectEqual(@as(usize, 0), later.deprecated.len);
    try std.testing.expectEqual(Problem.Why.unknown_version, later.problems[0].why);
    // A root that declares none has none, and no problem.
    try std.testing.expectEqual(null, (try of(&f.facts, f.project.sources[1].id)).declared);
}

test "a replacement names a std declaration or an external symbol, one of the two: both, or neither, is malformed where it is written" {
    var f: Fixture = undefined;
    try f.init(&.{
        .{ .name = "pkg/root.zig", .package = "pkg", .fingerprint = 7, .bytes =
        \\const std = @import("std");
        \\pub fn publish() void {}
        \\pub const lint_rules = .{
        \\    .version = 1,
        \\    .replaces = .{
        \\        .{ .symbol = "fsync", .with = publish, .why = "durable" },
        \\        .{ .std = std.Io.Dir.createFileAtomic, .symbol = "fsync", .with = publish, .why = "both" },
        \\        .{ .with = publish, .why = "neither" },
        \\    },
        \\};
        },
        .{ .name = "std", .bytes = fake_std, .selected = false },
    }, &.{.{ .from = 0, .spelling = "std", .target = 1 }});
    defer f.deinit();
    const rules = try of(&f.facts, f.project.sources[0].id);
    try std.testing.expectEqual(@as(usize, 1), rules.replaces.len);
    try std.testing.expectEqualStrings("fsync", rules.replaces[0].symbol.?);
    try std.testing.expectEqual(null, rules.replaces[0].std);
    try std.testing.expectEqualStrings("publish", f.name(rules.replaces[0].with));
    var whys: [4]Problem.Why = undefined;
    for (rules.problems, 0..) |problem, i| whys[i] = problem.why;
    try std.testing.expectEqualSlices(Problem.Why, &.{ .malformed, .malformed }, whys[0..rules.problems.len]);
}

test "a door entry names a declaration of the package: one that does not resolve or is another's is a problem where it is written, the rest read" {
    var f: Fixture = undefined;
    try f.init(&.{
        .{ .name = "pkg/root.zig", .package = "pkg", .fingerprint = 7, .bytes =
        \\const other = @import("other");
        \\pub fn publish() void {}
        \\pub fn flush() void {}
        \\const Ns = struct {};
        \\pub const lint_rules = .{
        \\    .version = 1,
        \\    .door = .{ flush, Ns.gone, other.thing },
        \\};
        },
        .{ .name = "other/root.zig", .package = "other", .fingerprint = 8, .selected = false, .bytes = "pub fn thing() void {}\n" },
    }, &.{.{ .from = 0, .spelling = "other", .target = 1 }});
    defer f.deinit();
    const rules = try of(&f.facts, f.project.sources[0].id);
    try std.testing.expectEqual(@as(usize, 3), rules.door.len);
    try std.testing.expectEqualStrings("flush", f.name(rules.door[0].reference));
    var whys: [4]Problem.Why = undefined;
    for (rules.problems, 0..) |problem, i| whys[i] = problem.why;
    try std.testing.expectEqualSlices(Problem.Why, &.{ .unresolved, .foreign }, whys[0..rules.problems.len]);
    for (rules.problems) |problem| try std.testing.expectEqual(Problem.Part.replaces, problem.part);
}

test "a replaced std member each target declares in a holder of its own is read in every holder that has it" {
    var f: Fixture = undefined;
    try f.init(&.{
        .{ .name = "pkg/root.zig", .package = "pkg", .fingerprint = 7, .bytes =
        \\const std = @import("std");
        \\pub fn publish() void {}
        \\pub const lint_rules = .{
        \\    .version = 1,
        \\    .replaces = .{
        \\        .{ .std = std.F.BOTH, .with = publish, .why = "two targets" },
        \\        .{ .std = std.F.ONE, .with = publish, .why = "one target" },
        \\        .{ .std = std.F.NONE, .with = publish, .why = "no target" },
        \\    },
        \\};
        },
        .{ .name = "std", .selected = false, .bytes =
        \\const native = @import("builtin").os.tag;
        \\pub const F = switch (native) {
        \\    .macos => struct { pub const BOTH = 1; pub const ONE = 2; },
        \\    .linux => struct { pub const BOTH = 3; },
        \\    else => void,
        \\};
        },
    }, &.{.{ .from = 0, .spelling = "std", .target = 1 }});
    defer f.deinit();
    const rules = try of(&f.facts, f.project.sources[0].id);
    try std.testing.expectEqual(@as(usize, 3), rules.replaces.len);
    try std.testing.expectEqual(@as(usize, 2), rules.replaces[0].std.?.declarations().len);
    try std.testing.expectEqual(@as(usize, 1), rules.replaces[1].std.?.declarations().len);
    try std.testing.expectEqual(@as(usize, 0), rules.replaces[2].std.?.declarations().len);
    try std.testing.expectEqual(@as(usize, 1), rules.problems.len);
    try std.testing.expectEqual(Problem.Why.unresolved, rules.problems[0].why);
}

test "a fork's copy of a package is the package by its stated identity, wherever its tree is" {
    var f: Fixture = undefined;
    try f.init(&.{
        .{ .name = "consumer", .bytes = "const parallax = @import(\"parallax\");\npub fn f() void {\n    _ = parallax;\n}\n" },
        .{ .name = ".zig-cache/bay/forks/parallax-1a2b/src/root.zig", .package = "parallax", .fingerprint = 11, .selected = false, .bytes = "const hunks = @import(\"hunks.zig\");\npub const lint_rules = .{ .version = 1, .deprecated = .{.{ .decl = hunks.walk, .with = hunks.next, .why = \"one walk\" }} };\n" },
        .{ .name = ".zig-cache/bay/forks/parallax-1a2b/src/hunks.zig", .package = "parallax", .fingerprint = 11, .selected = false, .bytes = "pub fn walk() void {}\npub fn next() void {}\n" },
    }, &.{
        .{ .from = 0, .spelling = "parallax", .target = 1 },
        .{ .from = 1, .spelling = "hunks.zig", .target = 2 },
    });
    defer f.deinit();
    const rules = try of(&f.facts, f.project.sources[1].id);
    try std.testing.expectEqual(@as(usize, 0), rules.problems.len);
    try std.testing.expectEqualStrings("parallax", rules.package.name);
    try std.testing.expectEqualStrings("walk", f.name(rules.deprecated[0].decl));
    try std.testing.expectEqualStrings("next", f.name(rules.deprecated[0].with.?));
}

/// Whether `value` is one of the `owing` types: a value of one, seen through `!` and `?`, or
/// (`pointer`) a pointer to one; a part that does not resolve shows none. A choice is one where
/// every part is, not where none is, and null where its parts differ.
fn owes(value: Facts.Value, owing: []const Facts.Container, pointer: bool) ?bool {
    var some = false;
    var every = true;
    for (Facts.valueParts(&value)) |part| {
        const one: bool = switch (part) {
            .error_union, .optional => |inner| owes(inner.*, owing, pointer) orelse return null,
            .pointer => |inner| if (pointer) owes(inner.child.*, owing, pointer) orelse return null else false,
            .container, .instance => |c| for (owing) |held| {
                if (held.file == c.file and held.scope == c.scope) break true;
            } else false,
            .alternatives => unreachable, // unreachable: valueParts gives no choice as a part
            else => false,
        };
        some = some or one;
        every = every and one;
    }
    if (some != every) return null;
    return some;
}

test "a pair of a type names its operations as its members, and where a transfer moves the obligation is read from the member's declaration" {
    var f: Fixture = undefined;
    try f.init(&.{.{ .name = "pkg/root.zig", .package = "pkg", .fingerprint = 7, .bytes =
        \\pub fn Guarded(comptime T: type) type {
        \\    return struct {
        \\        value: T,
        \\        pub const Guard = struct {
        \\            pub fn deinit(g: *Guard) void { _ = g; }
        \\            pub fn handOff(g: *Guard) Handoff { _ = g; return .{}; }
        \\            pub fn tryHandOff(g: *Guard) ?Handoff { _ = g; return null; }
        \\        };
        \\        pub const Handoff = struct {
        \\            pub fn release(h: *Handoff) void { _ = h; }
        \\        };
        \\    };
        \\}
        \\pub const Reservation = struct {
        \\    pub fn release(r: *Reservation) void { _ = r; }
        \\    pub fn moveInto(r: *Reservation, destination: *Reservation) void { _ = r; _ = destination; }
        \\};
        \\pub const lint_rules = .{
        \\    .version = 1,
        \\    .pairs = .{
        \\        .{ .type = .{ .generic = Guarded, .member = .Guard }, .release = .{.deinit}, .transfer = .{ .handOff, .tryHandOff } },
        \\        .{ .type = .{ .generic = Guarded, .member = .Handoff }, .release = .{.release} },
        \\        .{ .type = Reservation, .release = .{.release}, .transfer = .{.moveInto} },
        \\    },
        \\};
    }}, &.{});
    defer f.deinit();
    const rules = try of(&f.facts, f.project.sources[0].id);
    try std.testing.expectEqual(@as(usize, 0), rules.problems.len);
    try std.testing.expectEqualStrings("deinit", f.name(rules.pairs[0].release[0]));
    // To the result: a `Handoff`, and through `?` one that may be null.
    try std.testing.expect(rules.pairs[0].transfer[0].to == .result);
    try std.testing.expect(rules.pairs[0].transfer[1].to == .result);
    // Into the one parameter, the receiver aside, that points to an owing type.
    try std.testing.expectEqual(@as(usize, 1), rules.pairs[2].transfer[0].to.argument);
}

test "a pair is refused as written where its operations do not settle: a transfer to nothing or to two places, a teardown with no release, a member that is not there or no function" {
    const head =
        \\pub const R = struct {
        \\    pub const kind = 1;
        \\    pub fn release(r: *R) void { _ = r; }
        \\    pub fn deinit(r: *R) void { _ = r; }
        \\    pub fn drop(r: *R) void { _ = r; }
        \\    pub fn split(r: *R, a: *R, b: *R) void { _ = r; _ = a; _ = b; }
        \\};
        \\
    ;
    for ([_]struct { []const u8, Problem.Why }{
        .{ ".{ .type = R, .release = .{.release}, .transfer = .{.drop} }", .refused },
        .{ ".{ .type = R, .release = .{.release}, .transfer = .{.split} }", .refused },
        .{ ".{ .type = R, .teardown = .{.deinit} }", .refused },
        .{ ".{ .type = R, .release = .{.relase} }", .unresolved },
        .{ ".{ .type = R, .release = .{.kind} }", .refused },
    }) |case| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ head, "pub const lint_rules = .{ .version = 1, .pairs = .{", case[0], "} };\n" });
        defer std.testing.allocator.free(source);
        var f: Fixture = undefined;
        try f.init(&.{.{ .name = "pkg/root.zig", .package = "pkg", .fingerprint = 7, .bytes = source }}, &.{});
        defer f.deinit();
        const rules = try of(&f.facts, f.project.sources[0].id);
        try std.testing.expectEqual(@as(usize, 1), rules.problems.len);
        try std.testing.expectEqual(case[1], rules.problems[0].why);
    }
}

test "the run's rule table: every package's declared rules once, ordered by id, given ids from the first package id; one id declared by two packages is refused" {
    const rule = ".{ .id = .ID, .name = \"n\", .kind = .ban, .reads = .replaces, .default = true, .purpose = \"p\" }";
    var f: Fixture = undefined;
    try f.init(&.{
        .{ .name = "a/root.zig", .package = "a", .fingerprint = 1, .bytes = "const inner = @import(\"inner.zig\");\npub const lint_rules = .{ .version = 2, .include = .{inner.lint_rules}, .rules = .{" ++ rule ++ "} };\n" },
        // Read from its own root and through the include: one rule.
        .{ .name = "a/inner.zig", .package = "a", .fingerprint = 1, .bytes = "pub const lint_rules = .{ .version = 2, .rules = .{.{ .id = .A002, .name = \"m\", .kind = .hygiene, .reads = .exits, .default = false, .purpose = \"q\" }} };\n" },
        .{ .name = "b/root.zig", .package = "b", .fingerprint = 2, .bytes = "pub const lint_rules = .{ .version = 2, .rules = .{.{ .id = .B001, .name = \"o\", .kind = .ban, .reads = .governed, .default = true, .purpose = \"r\" }} };\n" },
    }, &.{.{ .from = 0, .spelling = "inner.zig", .target = 1 }});
    defer f.deinit();
    // `.ID` stands in the first root for a rule whose id sorts last.
    const found = table(&f.facts) catch |err| return err;
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("A002", found[0].name);
    try std.testing.expectEqualStrings("B001", found[1].name);
    try std.testing.expectEqualStrings("ID", found[2].name);
    try std.testing.expectEqual(first_package_id, @backingInt(found[0].id));
    try std.testing.expectEqual(first_package_id + 2, @backingInt(found[2].id));
    try std.testing.expectEqualStrings("b", found[1].declared.?.package);
    try std.testing.expectEqual(Inventory.Reads.governed, found[1].declared.?.reads);
    try std.testing.expect(!found[0].declared.?.default);

    var twice: Fixture = undefined;
    try twice.init(&.{
        .{ .name = "a/root.zig", .package = "a", .fingerprint = 1, .bytes = "pub const lint_rules = .{ .version = 2, .rules = .{" ++ rule ++ "} };\n" },
        .{ .name = "b/root.zig", .package = "b", .fingerprint = 2, .bytes = "pub const lint_rules = .{ .version = 2, .rules = .{" ++ rule ++ "} };\n" },
    }, &.{});
    defer twice.deinit();
    try std.testing.expectError(error.DuplicateRule, table(&twice.facts));
}
