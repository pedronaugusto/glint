//! The rules a package declares in a module root (glint-design §12): `pub const lint_rules = .{
//! .version = 1, ... }`, read once per root as the caller states the root's package (its name and
//! fingerprint), every reference through the one resolver. A rule asks this reader; none reads a
//! declaration's spelling to know what a package declares.
const std = @import("std");
const Ast = std.zig.Ast;
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");

/// The vocabulary's version this reader knows. A root declaring another is read as no rules,
/// with the version a problem: undecided in a consumer, a finding in the declarer.
pub const version: u64 = 1;

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

    pub fn declaration(self: Reference) ?Facts.Decl {
        return if (self == .decl) self.decl else null;
    }
};

/// A declaration the package's replacement stands for (P006's): a std declaration (`.std`), or an
/// external symbol by its link name (`.symbol = "fsync"`), which every `extern` of it binds; one or
/// the other.
pub const Replace = struct { std: ?Reference = null, symbol: ?[]const u8 = null, with: Reference, why: []const u8 };
/// A declaration of the package's to move off (Z011's).
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

    pub const Why = enum {
        /// `.version` is not this reader's (`version`): the rules are not read.
        unknown_version,
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
    replaces: []const Replace = &.{},
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
        found.replaces = try reader.replaces.toOwnedSlice(facts.gpa);
        found.deprecated = try reader.deprecated.toOwnedSlice(facts.gpa);
        found.roles = try reader.roles.toOwnedSlice(facts.gpa);
        found.pairs = try reader.pairs.toOwnedSlice(facts.gpa);
        found.problems = try reader.problems.toOwnedSlice(facts.gpa);
    }
    try memo.roots.put(facts.gpa, root, found);
    return found;
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
pub fn publication(facts: *Facts, library: anytype) Facts.ResolveError!*const Publication {
    const Roles = @TypeOf(library).Role;
    const vocabulary = comptime std.hash.Wyhash.hash(0, @typeName(Roles));
    const keyed = vocabulary ^ library.package.fingerprint;
    const memo = try facts.memo(Publications);
    if (memo.found.get(keyed)) |known| return known;
    var entries: std.ArrayList(Entry) = .empty;
    var gaps: std.ArrayList(Gap) = .empty;
    var pairs: std.ArrayList(Pair) = .empty;
    for (try facts.packageRoots(library.package)) |root| {
        const rules = try of(facts, root);
        if (rules.declared == null) try gaps.append(facts.gpa, .{ .root = root, .problem = null });
        for (rules.problems) |problem| try gaps.append(facts.gpa, .{ .root = root, .problem = problem });
        try pairs.appendSlice(facts.gpa, rules.pairs);
        for (rules.roles) |declared| {
            const role_value = roleValue(Roles, declared.role) orelse continue;
            const decl = declared.type.declaration() orelse continue;
            switch (try facts.declaration(decl)) {
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
                // A role on what is no type and no function: the declarer's own lint reports
                // the form; for its consumers the role is not read.
                else => try gaps.append(facts.gpa, .{ .root = root, .problem = .{ .file = decl.file, .node = facts.project.at(decl.file).model.declarations[@backingInt(decl.index)].node, .why = .malformed } }),
            }
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
pub fn operation(facts: *Facts, library: anytype, callee: Facts.Decl) Facts.ResolveError!?Operation {
    const found = try publication(facts, library);
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
pub fn role(facts: *Facts, library: anytype, value: Facts.Value) Facts.ResolveError!?@TypeOf(library).Role {
    const Roles = @TypeOf(library).Role;
    // A choice: the role every part agrees on, none where they differ or one has none.
    if (value == .alternatives) {
        var agreed: ?Roles = null;
        for (value.alternatives, 0..) |part, k| {
            const one = (try role(facts, library, part)) orelse return null;
            if (k != 0 and one != agreed.?) return null;
            agreed = one;
        }
        return agreed;
    }
    const found = (try entryOf(facts, library, value)) orelse return null;
    return @as(Roles, @fromBackingInt(@intCast(found.role)));
}

/// The fields only `library`'s package touches of a value's type (`.internal`), where its type is
/// one the package gives a role, seen as `role` sees it; null where it is none.
pub fn internalOf(facts: *Facts, library: anytype, value: Facts.Value) Facts.ResolveError!?[]const []const u8 {
    const found = (try entryOf(facts, library, value)) orelse return null;
    return found.internal;
}

/// The entry of the declaration `value` is, or is a type or instance of.
fn entryOf(facts: *Facts, library: anytype, value: Facts.Value) Facts.ResolveError!?Entry {
    const found = try publication(facts, library);
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
    deprecated: std.ArrayList(Deprecated) = .empty,
    roles: std.ArrayList(Role) = .empty,
    pairs: std.ArrayList(Pair) = .empty,
    problems: std.ArrayList(Problem) = .empty,

    const Error = Facts.ResolveError;

    fn tree(r: *const Reader, file: Project.FileId) *const Ast {
        return &r.facts.project.at(file).file.tree;
    }

    fn problem(r: *Reader, file: Project.FileId, node: Ast.Node.Index, why: Problem.Why) Error!void {
        try r.problems.append(r.facts.gpa, .{ .file = file, .node = node, .why = why });
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
        // The version first: a root of another version is not read at all.
        var known = false;
        for (literal.ast.fields) |field| if (std.mem.eql(u8, fieldName(t, field), "version")) {
            known = t.nodeTag(field) == .number_literal and (std.fmt.parseInt(u64, t.tokenSlice(t.nodeMainToken(field)), 10) catch 0) == version;
        };
        if (!known) return r.problem(decl.file, init, .unknown_version);
        for (literal.ast.fields) |field| {
            const name = fieldName(t, field);
            if (std.mem.eql(u8, name, "version")) continue;
            if (std.mem.eql(u8, name, "include")) {
                try r.includes(decl.file, field);
            } else if (std.mem.eql(u8, name, "replaces")) {
                for (try r.list(decl.file, field) orelse continue) |entry| try r.replace(decl.file, entry);
            } else if (std.mem.eql(u8, name, "deprecated")) {
                for (try r.list(decl.file, field) orelse continue) |entry| try r.deprecation(decl.file, entry);
            } else if (std.mem.eql(u8, name, "roles")) {
                for (try r.list(decl.file, field) orelse continue) |entry| try r.role(decl.file, entry);
            } else if (std.mem.eql(u8, name, "pairs")) {
                for (try r.list(decl.file, field) orelse continue) |entry| try r.pair(decl.file, entry);
            } else try r.problem(decl.file, field, .unknown_field);
        }
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
            if (owes(try r.facts.resolve(decl.file, result), owing, false)) return .result;
        }
        var found: ?usize = null;
        var it = proto.iterate(t);
        var position: usize = 0;
        while (it.next()) |param| : (position += 1) {
            const written = param.type_expr orelse continue;
            if (position == 0) continue; // The receiver is the value the obligation leaves.
            if (!owes(try r.facts.resolve(decl.file, written), owing, true)) continue;
            if (found != null) return null;
            found = position;
        }
        return if (found) |at| .{ .argument = at } else null;
    }

    /// The container a type declaration names: the type itself, or the one a type function
    /// returns. Null where it resolves to neither.
    fn containerOf(r: *Reader, decl: Facts.Decl) Error!?Facts.Container {
        return switch (try r.facts.declaration(decl)) {
            .container, .instance => |c| c,
            .function => |function| switch ((try r.facts.template(function)) orelse return null) {
                .container, .instance => |c| c,
                else => null,
            },
            else => null,
        };
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
    fn reference(r: *Reader, file: Project.FileId, node: Ast.Node.Index, whose: enum { std, own }) Error!Reference {
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
        const belongs = switch (whose) {
            .std => try r.facts.standard(found.file),
            .own => Identity.of(r.facts.project, found.file).eql(r.package),
        };
        if (!belongs) {
            try r.problem(file, node, .foreign);
            return .{ .foreign = found };
        }
        return .{ .decl = found };
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
        const decl = reference.declaration() orelse return "";
        return f.project.at(decl.file).model.declarations[@backingInt(decl.index)].name;
    }
};

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
        .{ .name = "next/root.zig", .package = "next", .fingerprint = 3, .selected = false, .bytes = "pub fn thing() void {}\npub const lint_rules = .{ .version = 2, .deprecated = .{.{ .decl = thing, .why = \"later\" }} };\n" },
    }, &.{.{ .from = 0, .spelling = "other", .target = 1 }});
    defer f.deinit();
    const rules = try of(&f.facts, f.project.sources[0].id);
    var whys: [3]Problem.Why = undefined;
    for (rules.problems, 0..) |problem, i| whys[i] = problem.why;
    try std.testing.expectEqualSlices(Problem.Why, &.{ .unresolved, .foreign, .unknown_field }, whys[0..rules.problems.len]);
    try std.testing.expect(rules.deprecated[0].decl == .unresolved);
    try std.testing.expectEqualStrings("publish", f.name(rules.deprecated[0].with.?));
    try std.testing.expect(rules.deprecated[1].decl == .foreign);
    try std.testing.expect(rules.deprecated[1].with == null);
    // Another version is read as no rules at all.
    const later = try of(&f.facts, f.project.sources[2].id);
    try std.testing.expectEqual(@as(usize, 0), later.deprecated.len);
    try std.testing.expectEqual(Problem.Why.unknown_version, later.problems[0].why);
    // A root that declares none has none, and no problem.
    try std.testing.expect((try of(&f.facts, f.project.sources[1].id)).declared == null);
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
    try std.testing.expect(rules.replaces[0].std == null);
    try std.testing.expectEqualStrings("publish", f.name(rules.replaces[0].with));
    var whys: [4]Problem.Why = undefined;
    for (rules.problems, 0..) |problem, i| whys[i] = problem.why;
    try std.testing.expectEqualSlices(Problem.Why, &.{ .malformed, .malformed }, whys[0..rules.problems.len]);
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
/// (`pointer`) a pointer to one.
fn owes(value: Facts.Value, owing: []const Facts.Container, pointer: bool) bool {
    var current = value;
    while (true) switch (current) {
        .error_union, .optional => |inner| current = inner.*,
        .pointer => |inner| {
            if (!pointer) return false;
            current = inner.child.*;
        },
        .container, .instance => |c| {
            for (owing) |each| if (each.file == c.file and each.scope == c.scope) return true;
            return false;
        },
        else => return false,
    };
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
