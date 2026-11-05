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

/// A std declaration the package's replacement stands for (P006's).
pub const Replace = struct { std: Reference, with: Reference, why: []const u8 };
/// A declaration of the package's to move off (Z011's).
pub const Deprecated = struct { decl: Reference, with: ?Reference, why: []const u8 };
/// What a type means: its role, by the enum literal's name, and the fields only the package may
/// touch (A001's), by name.
pub const Role = struct { type: Reference, role: []const u8, internal: []const []const u8 };
/// An obligation no body shows: what acquires it and what discharges it.
pub const Pair = struct { acquire: Reference, release: []const Reference, transfer: []const Reference };

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
        var entry: Replace = .{ .std = .unresolved, .with = .unresolved, .why = "" };
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = r.tree(file).fullStructInit(&buffer, node) orelse return r.problem(file, node, .malformed);
        for (literal.ast.fields) |field| {
            const name = fieldName(r.tree(file), field);
            if (std.mem.eql(u8, name, "std")) {
                entry.std = try r.reference(file, field, .std);
            } else if (std.mem.eql(u8, name, "with")) {
                entry.with = try r.reference(file, field, .own);
            } else if (std.mem.eql(u8, name, "why")) {
                entry.why = try r.string(file, field);
            } else try r.problem(file, field, .unknown_field);
        }
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
            } else if (std.mem.eql(u8, name, "internal")) {
                var names: std.ArrayList([]const u8) = .empty;
                for (try r.list(file, field) orelse continue) |each| try names.append(r.facts.gpa, try r.enumLiteral(file, each));
                entry.internal = try names.toOwnedSlice(r.facts.gpa);
            } else try r.problem(file, field, .unknown_field);
        }
        try r.roles.append(r.facts.gpa, entry);
    }

    fn pair(r: *Reader, file: Project.FileId, node: Ast.Node.Index) Error!void {
        var entry: Pair = .{ .acquire = .unresolved, .release = &.{}, .transfer = &.{} };
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = r.tree(file).fullStructInit(&buffer, node) orelse return r.problem(file, node, .malformed);
        for (literal.ast.fields) |field| {
            const name = fieldName(r.tree(file), field);
            if (std.mem.eql(u8, name, "acquire")) {
                entry.acquire = try r.reference(file, field, .own);
            } else if (std.mem.eql(u8, name, "release") or std.mem.eql(u8, name, "transfer")) {
                var each: std.ArrayList(Reference) = .empty;
                for (try r.list(file, field) orelse continue) |one| try each.append(r.facts.gpa, try r.reference(file, one, .own));
                const owned = try each.toOwnedSlice(r.facts.gpa);
                if (std.mem.eql(u8, name, "release")) entry.release = owned else entry.transfer = owned;
            } else try r.problem(file, field, .unknown_field);
        }
        try r.pairs.append(r.facts.gpa, entry);
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
        const made_by = switch (try r.facts.definition(file, function orelse return .not)) {
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
    try std.testing.expectEqualStrings("createFileAtomic", f.name(rules.replaces[0].std));
    try std.testing.expectEqualStrings("publish", f.name(rules.replaces[0].with));
    try std.testing.expectEqualStrings("airlock's publish is durable", rules.replaces[0].why);
    try std.testing.expectEqualStrings("old", f.name(rules.deprecated[0].decl));
    // The root's own role, then the included one; the include back to the root reads nothing again.
    try std.testing.expectEqual(@as(usize, 2), rules.roles.len);
    try std.testing.expectEqualStrings("Once", f.name(rules.roles[0].type));
    try std.testing.expectEqualStrings("Secret", f.name(rules.roles[1].type));
    try std.testing.expectEqualStrings("secret", rules.roles[1].role);
    try std.testing.expectEqualStrings("data", rules.roles[1].internal[0]);
    try std.testing.expectEqualStrings("acquire", f.name(rules.pairs[0].acquire));
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
