//! Optional explicitly adopted published-type obligations. No security or lifetime proof.
const std = @import("std");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const Governed = @import("Governed.zig");
const Context = @import("RuleContext.zig");
const Contract = @import("AegisContract.zig");
const Ids = @import("AegisRules.zig");
const Danger = @import("Danger.zig");
const stdCall = Governed.stdCall;
const Is = Governed.Is;
const isStd = Governed.isStd;
const Shapes = @import("DangerShapes.zig");
const Rule = @import("Rule.zig").Rule;
const Report = @import("Report.zig");
const PackageRules = @import("PackageRules.zig");
const Ast = std.zig.Ast;
pub const access = Ids.access;
pub const scalar = Ids.scalar;
// The danger rules (designs/aegis.md §7): each finds where its danger exists and aegis's type is
// the answer, from what the code resolves to.
// Identities no rule of the pack carries, named here only for preflight's policy, which lists them:
// A006 and A018 (removed in 0.8), and the rules aegis now declares itself or that went with the
// flow engine (AegisRules).
pub const recursion = Ids.recursion;
pub const diagnostics = Ids.diagnostics;
pub const shared_state = Ids.shared_state;
pub const untrusted_input = Ids.untrusted_input;
pub const integers = Ids.integers;
pub const bounded_work = Ids.bounded_work;
pub const contracts = Ids.contracts;
pub const cancellation = Ids.cancellation;
pub const lock_order = Ids.lock_order;
/// The danger rules: each finds where a danger exists and aegis's type is the answer.
pub const danger = [_]Rule{ lifetimes, identity, unsafe_set };
pub const lifetimes = Ids.lifetimes;
pub const identity = Ids.identity;
pub const unsafe_set = Ids.unsafe_set;
/// Aegis's package, as its `build.zig.zon` names it: a caller states it for aegis's files.
pub const package = Contract.package;
/// The roles the pack reads from what aegis declares, and aegis as a library of them: a project's
/// own rule reads a role through `RuleContext.role(library, value)`.
pub const Role = Contract.Kind;
pub const library = Contract.library;
/// The first file outside aegis whose import reaches aegis (`Facts.packageRoots`): a file of
/// aegis's package, by the identity the caller states, whatever the program names it after. A
/// module of aegis's name that is not of aegis's package is not aegis.
pub fn importer(gpa: std.mem.Allocator, project: *const Project) Facts.ResolveError!?Project.FileId {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var facts: Facts = .{ .project = project, .gpa = arena.allocator(), .known = Contract.package };
    const roots = try facts.packageRoots(Contract.package);
    for (project.imports) |mapping| {
        if (!mapping.in.inProgram() or facts.knownFile(mapping.from)) continue;
        if (std.mem.findScalar(Project.FileId, roots, mapping.target) != null) return mapping.from;
    }
    return null;
}

pub const rules = [_]Context.Rule{
    .{ .definition = .{ .id = access, .name = "A001", .group = .family_policy, .purpose = "secret disclosure or shared-state access without a live capability", .version = 2, .exception = .aegis }, .check = checkAccess },
    .{ .definition = .{ .id = scalar, .name = "A004", .group = .family_policy, .purpose = "domain/unit or all-build integer checks bypassed by raw arithmetic/casts", .version = 2, .exception = .aegis }, .check = checkScalar },
    .{ .definition = .{ .id = lifetimes, .name = "A014", .group = .family_policy, .purpose = "pointer that outlives what it points into", .exception = .aegis }, .check = checkLifetimes },
    .{ .definition = .{ .id = identity, .name = "A016", .group = .family_policy, .purpose = "identifying integers of one type that one may pass for another", .exception = .aegis }, .check = checkIdentity },
    .{ .definition = .{ .id = unsafe_set, .name = "A019", .group = .family_policy, .purpose = "operation Zig leaves unchecked", .exception = .aegis }, .check = checkUnsafeSet },
};
fn checkLifetimes(c: *Context) Context.Error!void {
    if (!try begin(c, lifetimes)) return;
    try Danger.lifetimes(c, lifetimes);
}
fn checkIdentity(c: *Context) Context.Error!void {
    if (try begin(c, identity)) try Shapes.identity(c, identity);
}
fn checkUnsafeSet(c: *Context) Context.Error!void {
    if (!try begin(c, unsafe_set)) return;
    try Danger.unsafeSet(c, unsafe_set);
}
/// Starts a check of this file. What a `lint_rules` it declares says that glint cannot read is
/// reported where it is written, in whatever package (`ownRules`). The library's own files are
/// its safe-type internals; a root whose roles are not all read is reported where the library is
/// imported, so a renamed declaration cannot make a gate quietly stop seeing it.
fn begin(c: *Context, rule: Rule) Context.Error!bool {
    if (rule == access) try ownRules(c);
    if (try c.inLibrary(Contract.library, c.file)) return false;
    if (try c.drift(Contract.library)) |gap| try c.undecided(rule, gap.start, .unresolved, gap.detail);
    // Every rule of the pack judges a generic at its bindings: one on the surface that nothing
    // the run compiles binds is undecided at its name (main's ruling, 2026-11-04).
    const tree = try c.project.syntax(try c.source());
    for (c.project.at(c.file).model.declarations, 0..) |decl, i| {
        if (decl.kind != .function) continue;
        if (!try c.facts.unboundOnSurface(.{ .file = c.file, .index = @fromBackingInt(@intCast(i)) })) continue;
        try c.undecided(rule, tree.tokenStart(decl.token), .unresolved, Facts.unbound_generic);
    }
    return true;
}
/// Once per file (under A001), in any package: each part of a `lint_rules` this file declares
/// that glint cannot read (PackageRules.Problem: a reference that does not resolve, a role no
/// pack of the run reads, ...), where it is written, so the package's own lint catches what would
/// leave its types plain in the programs that import it.
fn ownRules(c: *Context) Context.Error!void {
    const declared = try PackageRules.of(c.facts, c.file);
    if (declared.declared == null) return;
    const tree = &c.project.at(c.file).file.tree;
    for (declared.problems) |problem| if (problem.file == c.file) {
        try c.at(access, tree.firstToken(problem.node), try c.allocator.print("lint_rules: {t}: glint does not read this part, so the programs that import this package do not know what it declares", .{problem.why}));
    };
}
fn checkAccess(c: *Context) Context.Error!void {
    if (!try begin(c, access)) return;
    const tree = try c.project.syntax(try c.source());
    const made_by_constructor = try constructed(c);
    // Each store's place (`x.f = v`, `x.f += v`, each a destructure writes: `p.bytes, n = …`).
    if (made_by_constructor.len != 0) for (try Facts.accesses.storesIn(c.facts, c.file)) |site| {
        if (site.target) |target| try checkFieldWrite(c, tree, target, site.node, made_by_constructor);
    };
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const form = Facts.accesses.formOf(tree.nodeTag(node));
        try checkWhole(c, tree, node);
        try checkGenericBinding(c, tree, node);
        if (made_by_constructor.len != 0) {
            try checkLiteral(c, tree, node, made_by_constructor);
            try checkMade(c, tree, node, made_by_constructor);
            if (form == .address_of) {
                try checkFieldWrite(c, tree, tree.nodeData(node).node, node, made_by_constructor);
                try checkWholeAddress(c, tree, node);
            }
        }
        try checkFieldBuiltin(c, tree, node);
        try checkByteRead(c, tree, node);
        if (form != .member) continue;
        // A member read `x.f`: its name and holder as the place's path has them.
        const path = try Facts.accesses.pathOf(c.facts, c.file, node);
        const step = path.steps[0];
        if (step.kind != .field) continue;
        const name = step.name orelse continue;
        if (!try anyInternal(c, name)) continue;
        const holder = path.steps[1].node;
        const token = tree.lastToken(node);
        if (try typeValue(c, holder)) continue;
        if (try refuted(c, node, name)) continue;
        const k = (try requiredOwner(c, holder, access, token)) orelse continue;
        try reportInternal(c, token, try internalField(c, try c.facts.resolve(c.file, holder), k, name));
    }
}

/// A read of a field only aegis touches: a finding where it is one, undecided where only some
/// of the role's types keep it and the holder's type does not resolve.
fn reportInternal(c: *Context, token: Ast.TokenIndex, found: Internal) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    switch (found) {
        .yes => try c.at(access, token, "published aegis backing field bypasses exposure/guard/ownership contract; review this access"),
        .unknown => try c.undecided(access, tree.tokenStart(token), .unresolved, "a field only some aegis types of this role keep behind their operations, on a value glint does not know to be one of them"),
        .no => {},
    }
}

/// A backing field named by a builtin that names a field by a string (`Governed.fieldBuiltin`:
/// `@field`, `@offsetOf`, `@bitOffsetOf`, `@fieldParentPtr`), as a member access names it: by a
/// name it spells (`@field(g, "data")`, `"\x64ata"`, a `const` that holds it), by each field
/// of a struct whose `field_names` it ranges over that is one; by a name it computes, any field
/// of the holder, undecided where the holder keeps a backing field. `@field` of a type names a
/// declaration; the others name a field of the type they are given or point into.
fn checkFieldBuiltin(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!void {
    const by = Governed.fieldBuiltin(tree, node) orelse return;
    const token = tree.nodeMainToken(node);
    const named = try c.facts.fieldName(c.file, by.name);
    switch (named) {
        .name => |name| if (!try anyInternal(c, name)) return,
        .each_of, .names => if (!try anyNamedInternal(c, named)) return,
        .computed => {},
    }
    const value = try Governed.fieldHolder(c, node, by);
    const k: Contract.Kind = if (by.holder) |holder| blk: {
        if (Facts.isBuiltin(tree, node, "@field") and try typeValue(c, holder)) return;
        break :blk (try requiredOwner(c, holder, access, token)) orelse return;
    } else switch (try perBuild(c, value)) {
        .owner => |k| k,
        .other => return,
        .unknown => return c.undecided(access, tree.tokenStart(token), .unresolved, "candidate receiver/value has no resolved operation contract"),
    };
    if (named == .computed) {
        if (try keepsInternal(c, value, k) != .no) try c.undecided(access, tree.tokenStart(token), .unresolved, "a name a builtin computes may be a published aegis backing field");
        return;
    }
    try reportInternal(c, token, try namedInternal(c, named, value, k));
}
/// Whether a name `@field` spells or ranges over may be a field only aegis touches of any type.
fn anyNamedInternal(c: *Context, named: Facts.FieldName) Context.Error!bool {
    const found = try PackageRules.publication(c.facts, Contract.Kind, Contract.library);
    for (found.entries) |entry| for (entry.internal) |name| if (c.facts.mayName(named, name)) return true;
    return false;
}
/// Whether a name `@field` spells or ranges over is a field only aegis touches of `holder`
/// (`internalField`): one it is makes the read one, one it may be makes it undecided.
fn namedInternal(c: *Context, named: Facts.FieldName, holder: Facts.Value, k: Contract.Kind) Context.Error!Internal {
    switch (named) {
        .name => |name| return internalField(c, holder, k, name),
        .computed => return .unknown,
        .each_of, .names => {
            var found: Internal = .no;
            const entries = (try PackageRules.publication(c.facts, Contract.Kind, Contract.library)).entries;
            for (entries) |entry| for (entry.internal) |name| {
                if (!c.facts.mayName(named, name)) continue;
                switch (try internalField(c, holder, k, name)) {
                    .yes => return .yes,
                    .unknown => found = .unknown,
                    .no => {},
                }
            };
            return found;
        },
    }
}

/// The bytes of a published owner read outside aegis: a std byte view of it
/// (`std.mem.asBytes(s)`, `toBytes`, `sliceAsBytes`), `@bitCast` of it, or `@ptrCast` of a
/// pointer to it into a pointer to another type, reads every field it keeps behind its
/// operations at once. A byte view of what does not resolve is undecided where it may be an
/// owner, as is an owner given to a call that may be a byte view, or cast to a pointer whose
/// type does not resolve.
fn checkByteRead(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!void {
    // Why the call may be a byte view or not, where it is not known to be one.
    var maybe: ?Facts.Unknown = null;
    const operand: Ast.Node.Index = blk: {
        if (Facts.builtinName(tree, node)) |name| {
            const pointer = std.mem.eql(u8, name, "@ptrCast");
            if (!pointer and !std.mem.eql(u8, name, "@bitCast")) return;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 1) return;
            // A pointer cast to the owner's own type reads nothing (`@ptrCast(@alignCast(p))`).
            if (pointer) switch (sameType(try c.facts.castTypeIn(null, c.file, node), try c.facts.resolve(c.file, args[0]))) {
                .yes => return,
                .no => {},
                .unknown => |why| maybe = why,
            };
            break :blk args[0];
        }
        const call = (try Facts.calls.at(c.facts, c.file, node)) orelse return;
        const args = switch (call.args) {
            .known => |known| known,
            .unknown => return,
        };
        if (args.len != 1) return;
        for ([_][]const u8{ "mem.asBytes", "mem.toBytes", "mem.sliceAsBytes" }) |path| switch (try stdCall(c, node, path)) {
            .yes => {
                maybe = null;
                break :blk args[0];
            },
            .no => {},
            .unknown => |why| maybe = why,
        };
        if (maybe != null) break :blk args[0];
        return;
    };
    // The place whose bytes it reads: what `&` takes the address of, through parentheses.
    var place = Facts.ungrouped(tree, operand);
    while (Facts.accesses.formOf(tree.nodeTag(place)) == .address_of) place = Facts.ungrouped(tree, tree.nodeData(place).node);
    if (try typeValue(c, place)) return;
    const token = tree.nodeMainToken(node);
    switch (try ownerKind(c, place, access)) {
        .owner => |k| switch (try keepsInternal(c, try c.facts.resolve(c.file, place), k)) {
            .yes => {
                if (maybe) |why| return c.unknown(access, node, why);
                try c.at(access, token, "the bytes of a published aegis owner read whole bypass its exposure/guard/ownership contract; use its operations");
            },
            .unknown => try c.undecided(access, tree.tokenStart(token), .unresolved, "the bytes of a value of an aegis role only some of whose types keep fields behind their operations, whose type does not resolve"),
            .no => {},
        },
        .other, .unknown => {},
    }
}
/// Whether two values are, past their pointers, optionals and error unions, one container:
/// unknown where either does not resolve.
const Same = union(enum) { yes, no, unknown: Facts.Unknown };
fn sameType(a: Facts.Value, b: Facts.Value) Same {
    const x = switch (pointee(a)) {
        .instance, .container => |found| found,
        .unknown => |why| return .{ .unknown = why },
        // A choice of types: one of them may be another.
        .alternatives => return .{ .unknown = .unsupported },
        else => return .no,
    };
    const y = switch (pointee(b)) {
        .instance, .container => |found| found,
        .unknown => |why| return .{ .unknown = why },
        .alternatives => return .{ .unknown = .unsupported },
        else => return .no,
    };
    return if (x.file == y.file and x.scope == y.scope) .yes else .no;
}
/// A value past its pointers, optionals and error unions.
fn pointee(value: Facts.Value) Facts.Value {
    var at = value;
    while (true) at = switch (at) {
        .pointer => |inner| inner.child.*,
        .optional, .error_union => |inner| inner.*,
        // A choice is read by its caller.
        .alternatives => return at,
        else => return at,
    };
}
/// The published types only their own constructor may make: `err.PublicSource`, whose
/// `classify` takes the reviewed reason that a literal of it skips.
fn constructed(c: *Context) Context.Error![]const Facts.Container {
    const found = try PackageRules.publication(c.facts, Contract.Kind, Contract.library);
    var out: std.ArrayList(Facts.Container) = .empty;
    for (found.entries) |entry| if (entry.target == .container and @as(Contract.Kind, @fromBackingInt(@intCast(entry.role))) == .public_source) try out.append(c.allocator, entry.target.container);
    return out.items;
}
/// A struct literal of a type only its constructor makes, outside the library: a finding where
/// its result type is one, undecided where it could be (it names exactly the type's fields,
/// every one without a default among them) and its place does not resolve.
fn checkLiteral(c: *Context, tree: *const Ast, node: Ast.Node.Index, targets: []const Facts.Container) Context.Error!void {
    var buffer: [2]Ast.Node.Index = undefined;
    const literal = tree.fullStructInit(&buffer, node) orelse return;
    var fits = false;
    for (targets) |target| fits = fits or try namesFields(c, tree, literal, target);
    if (!fits) return;
    switch (try typed(c.facts, try c.facts.literalType(c.file, node), 0)) {
        .owner => |k| if (k == .public_source) try c.at(access, tree.firstToken(node), "public text built by a literal skips its reviewed classification; use err.PublicSource.classify(reason, bytes)"),
        .other => {},
        .unknown => try c.undecided(access, tree.tokenStart(tree.firstToken(node)), .unresolved, "a literal that may be a public source has no resolved result type"),
    }
}
/// A value of a type only its constructor makes, made outside the library other than by a
/// literal (`checkLiteral`): by a call outside the program that is no function of the type's
/// package, or a reflective one of it (`Governed.madeByCall`: `std.mem.zeroInit(PublicSource,
/// .{ .bytes = b })`), or by reinterpreting another type (`Governed.madeByCast`: `@ptrCast` of
/// a `*const Text`). The program's own function is judged by its body.
fn checkMade(c: *Context, tree: *const Ast, node: Ast.Node.Index, targets: []const Facts.Container) Context.Error!void {
    const made = if (Facts.calls.written(tree, node)) try Governed.madeByCall(c, node, targets) else try Governed.madeByCast(c, node, targets);
    const token = tree.nodeMainToken(node);
    switch (made) {
        .no => {},
        .unknown => try c.undecided(access, tree.tokenStart(token), .unresolved, "a reflective constructor or a cast whose result does not resolve may make a public source without its reviewed classification"),
        .yes => |callee| {
            if (callee) |function| if (try c.inLibrary(Contract.library, function.file)) return;
            try c.at(access, token, "public text made other than by its constructor skips its reviewed classification; use err.PublicSource.classify(reason, bytes)");
        },
    }
}
/// A whole value read of a published owner that keeps fields behind its operations: `p.*` of a
/// pointer to one, used as a value (copied into a variable, a store, an argument, a literal, a
/// result), reads every one of those fields at once, outside the owner's package (std's
/// `autoHash(&h, s.*)`, `meta.eql(a.*, b.*)`, a `{any}` print of `g.*`). Taking its address, a
/// member of it, or storing into it reads none. A pointer whose type does not resolve is
/// judged where its fields are named.
fn checkWhole(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!void {
    if (Facts.accesses.formOf(tree.nodeTag(node)) != .deref) return;
    const operand = tree.nodeData(node).node;
    if (try typeValue(c, operand)) return;
    const k = switch (try ownerKind(c, operand, access)) {
        .owner => |k| k,
        .other, .unknown => return,
    };
    const token = tree.nodeMainToken(node);
    const internal = try keepsInternal(c, try c.facts.resolve(c.file, operand), k);
    if (internal == .no) return;
    switch (try wholeRead(c, tree, node)) {
        .no => {},
        .unknown => |why| try c.unknown(access, node, why),
        .yes => if (internal == .yes)
            try c.at(access, token, "a published aegis owner read whole reads every field it keeps behind its exposure/guard/ownership contract; use its operations")
        else
            try c.undecided(access, tree.tokenStart(token), .unresolved, "a value of an aegis role only some of whose types keep fields behind their operations, read whole"),
    }
}
/// Whether the value at `node` is taken where it stands, through what carries it (parentheses,
/// a branch, a `break`): copied, stored, handed, returned or operated on, as opposed to a
/// member read of it, its address, a store into it, or a discard.
fn wholeRead(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!Same {
    var at = node;
    for (0..64) |_| switch (try Facts.accesses.useOf(c.facts, c.file, at)) {
        .carried => |on| at = on.into,
        .statement, .typed, .written, .updated, .discarded, .member, .element, .sliced, .dereferenced, .index, .address, .callee, .matched, .logic => return .no,
        // What only a type reads takes no value (`@TypeOf(p.*)`, `@sizeOf`).
        .builtin_argument => |argument| {
            const name = Facts.builtinName(tree, argument.call) orelse return .yes;
            for ([_][]const u8{ "@TypeOf", "@sizeOf", "@alignOf", "@bitSizeOf" }) |each| if (std.mem.eql(u8, name, each)) return .no;
            return .yes;
        },
        .unknown => |why| return .{ .unknown = why },
        else => return .yes,
    };
    return .{ .unknown = .budget };
}
/// An owner that keeps fields behind its operations, handed to a call whose callee's body is
/// not read here with it. By value to a function outside the program and outside aegis (std's
/// `autoHash(&h, s)`): that function reads it whole, every one of those fields. Through a
/// pointer, by value or in a literal, to a generic parameter (`anytype`, or a type written with
/// the callee's own parameter) of a function outside aegis whose file this run does not check
/// (another file of the program, a dependency, std): the binding is never judged, so it is
/// undecided at the call (main's ruling, 2026-11-11).
fn checkGenericBinding(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!void {
    if (!Facts.calls.written(tree, node)) return;
    const call = (try Facts.calls.at(c.facts, c.file, node)) orelse return;
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => return,
    };
    const callees: []const Facts.Decl = switch (call.callee) {
        .function => |function| &.{function},
        .choice => |each| each,
        .any => return,
    };
    for (callees) |callee| {
        if (try c.inLibrary(Contract.library, callee.file)) continue;
        if (c.project.at(callee.file).input.selected) continue;
        const outside = !try c.facts.program(callee.file);
        for (args, 0..) |arg, position| {
            // A pointer's dereference handed whole is read whole (`checkWhole`).
            if (Facts.accesses.formOf(tree.nodeTag(Facts.ungrouped(tree, arg))) == .deref) continue;
            if (try typeValue(c, arg)) continue;
            const value = try c.facts.resolve(c.file, arg);
            const k = switch (try perBuild(c, value)) {
                .owner => |k| k,
                .other, .unknown => continue,
            };
            const internal = try keepsInternal(c, value, k);
            if (internal == .no) continue;
            const token = tree.firstToken(arg);
            if (outside and value == .instance and internal == .yes) {
                try c.at(access, token, "a published aegis owner handed by value to a function outside the program is read whole there, every field it keeps behind its exposure/guard/ownership contract; use its operations");
                continue;
            }
            if (!genericParameter(c, callee, position)) continue;
            try c.undecided(access, tree.tokenStart(token), .unresolved, "an aegis owner bound to a generic parameter of a function this run does not read with that binding: it may read the fields kept behind its operations");
        }
    }
}
/// Whether `function`'s parameter at `position` is generic: `anytype`, or a type written with
/// one of the function's own parameters (`T`, `@TypeOf(a)`).
fn genericParameter(c: *Context, function: Facts.Decl, position: usize) bool {
    const tree = &c.project.at(function.file).file.tree;
    const model = &c.project.at(function.file).model;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(function.index)].node) orelse return false;
    var parameters = proto.iterate(tree);
    var at: usize = 0;
    while (parameters.next()) |parameter| : (at += 1) {
        if (at != position) continue;
        const written = parameter.type_expr orelse return true;
        return Governed.refersToParameter(tree, model, proto, written);
    }
    // Past the last parameter: a variadic one's, read as `anytype`.
    return true;
}
/// A field of a type only its constructor makes, written in place (`p.bytes = x`,
/// `@field(p, "bytes") = x`) or its address taken (`&p.bytes`), outside the library: its
/// classification no longer describes what it holds. A finding where the value is one,
/// undecided where it does not resolve.
fn checkFieldWrite(c: *Context, tree: *const Ast, target: Ast.Node.Index, at: Ast.Node.Index, targets: []const Facts.Container) Context.Error!void {
    const place = Facts.ungrouped(tree, target);
    const base: Ast.Node.Index, const name: Facts.FieldName = switch (Facts.accesses.formOf(tree.nodeTag(place))) {
        .member => .{ tree.nodeData(place).node_and_token[0], Facts.FieldName{ .name = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(place).node_and_token[1])) } },
        .builtin => blk: {
            if (!Facts.isBuiltin(tree, place, "@field")) return;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, place, &buffer);
            if (args.len != 2) return;
            break :blk .{ args[0], try c.facts.fieldName(c.file, args[1]) };
        },
        else => return,
    };
    // The name it writes may be a field the type declares: the one it spells, one of a
    // struct's field names it ranges over, or any where it computes the name.
    var declared = false;
    for (targets) |container| {
        const model = &c.project.at(container.file).model;
        for (model.declarations) |d| {
            if (d.kind != .field or d.scope != container.scope) continue;
            declared = declared or c.facts.mayName(name, d.name);
        }
    }
    if (!declared) return;
    switch (try perBuild(c, try c.facts.resolve(c.file, base))) {
        .owner => |k| if (k == .public_source) try c.at(access, tree.nodeMainToken(at), "a public source's field written in place keeps a classification that no longer describes it; make a new one with err.PublicSource.classify(reason, bytes)"),
        .other => {},
        .unknown => try c.undecided(access, tree.tokenStart(tree.nodeMainToken(at)), .unresolved, "a field written in place may be a public source's: its classification would no longer describe it"),
    }
}
/// A public source's own address taken, where what holds it can be written (a `var`, a part of
/// one, or what a pointer points at), and handed where it may be written: a byte view of it
/// (`std.mem.asBytes(&p)`, then `@memcpy` into it), a swap or copy over it, a reinterpreting
/// cast, `@memcpy` or `@memset` into it, or a call whose parameter there is no `*const` pointer.
/// Its fields then hold what its classification never saw. aegis's own functions are the
/// contract. A call whose parameter does not resolve, or whose callee may write through it,
/// is undecided.
fn checkWholeAddress(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!void {
    const operand = tree.nodeData(node).node;
    switch (try perBuild(c, try c.facts.resolve(c.file, operand))) {
        .owner => |k| if (k != .public_source) return,
        .other, .unknown => return,
    }
    if (!try writable(c, tree, operand)) return;
    const model = &c.project.at(c.file).model;
    const parent = model.parentOf(node) orelse return;
    const rewritten = "a public source's bytes handed where they are written keep a classification that no longer describes them; make a new one with err.PublicSource.classify(reason, bytes)";
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&buffer, parent)) |call| {
        for ([_][]const u8{ "mem.asBytes", "mem.sliceAsBytes", "mem.swap", "mem.copyForwards", "mem.copyBackwards" }) |path| switch (try stdCall(c, parent, path)) {
            .yes => return c.at(access, tree.nodeMainToken(parent), rewritten),
            .no => {},
            .unknown => |why| return c.unknown(access, node, why),
        };
        // The parameter it is given to: its position among what the call passes, a bound
        // receiver first (`Facts.calls`).
        if (std.mem.findScalar(Ast.Node.Index, call.ast.params, node) == null) return;
        const site = (try Facts.calls.at(c.facts, c.file, parent)).?; // unreachable: `parent` is a call
        const callee = switch (site.callee) {
            // A function: no alias, its own origin.
            .function => |decl| decl,
            else => return c.undecided(access, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a public source's address handed to a call that does not resolve, which may write it"),
        };
        if (try c.inLibrary(Contract.library, callee.file)) return;
        const position = switch (site.args) {
            .known => |args| std.mem.findScalar(Ast.Node.Index, args, node).?, // unreachable: `node` is one of the call's arguments
            .unknown => |why| return c.unknown(access, node, why),
        };
        if (try constParameter(c, callee, position)) return;
        return c.undecided(access, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a public source's address handed to a function that may write through it");
    }
    for ([_][]const u8{ "@ptrCast", "@memcpy", "@memset", "@alignCast" }) |name| {
        if (Facts.isBuiltin(tree, parent, name)) return c.at(access, tree.nodeMainToken(parent), rewritten);
    }
}

/// Whether a place can be written: a `var`, a part of one, or what a pointer points at; a
/// `const` and a parameter held by value cannot.
fn writable(c: *Context, tree: *const Ast, place: Ast.Node.Index) Context.Error!bool {
    const path = try Facts.accesses.pathOf(c.facts, c.file, place);
    // Through a pointer: what it points at. The pointer crossed nearest the place decides:
    // nothing is written through a name declared a pointer to `const`; any other pointer's
    // memory, whatever holds the pointer, can be.
    for (path.steps[0 .. path.steps.len - 1], path.steps[1..]) |step, below| if (step.crosses) return !constPointerName(c, tree, below.node);
    const model = &c.project.at(c.file).model;
    const root = path.steps[path.steps.len - 1].node;
    if (!isName(model, root)) return true;
    const index = model.reference(root).?.declaration orelse return true; // unreachable: a name has the model's reference
    const decl = model.declarations[@backingInt(index)];
    return switch (decl.kind) {
        .variable => tree.tokenTag((tree.fullVarDecl(decl.node) orelse return true).ast.mut_token) == .keyword_var,
        .parameter => false,
        else => true,
    };
}

/// Whether `node` names a parameter or a variable declared with a pointer-to-`const` type
/// (`p: *const T`, `const b: []const u8 = ...`), through which nothing is written.
fn constPointerName(c: *Context, tree: *const Ast, node: Ast.Node.Index) bool {
    const model = &c.project.at(c.file).model;
    if (!isName(model, node)) return false;
    const index = model.reference(node).?.declaration orelse return false; // unreachable: a name has the model's reference
    const decl = model.declarations[@backingInt(index)];
    const written = switch (decl.kind) {
        .parameter => c.facts.parameterTypeNode(.{ .file = c.file, .index = index }),
        .variable => (tree.fullVarDecl(decl.node) orelse return false).ast.type_node.unwrap(),
        else => null,
    } orelse return false;
    const pointer = tree.fullPtrType(written) orelse return false;
    return pointer.const_token != null;
}

/// Whether `function`'s parameter at `position` is a pointer to `const` (`*const T`,
/// `[]const T`), through which nothing is written.
fn constParameter(c: *Context, function: Facts.Decl, position: usize) Context.Error!bool {
    const tree = &c.project.at(function.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return false;
    var it = proto.iterate(tree);
    var at: usize = 0;
    while (it.next()) |param| : (at += 1) {
        if (at != position) continue;
        const written = param.type_expr orelse return false;
        const pointer = tree.fullPtrType(written) orelse return false;
        return pointer.const_token != null;
    }
    return false;
}

/// Whether a literal could be a value of `container`: every field it names is one of the
/// container's, and it names every field that has no default.
fn namesFields(c: *Context, tree: *const Ast, literal: Ast.full.StructInit, container: Facts.Container) Context.Error!bool {
    const model = &c.project.at(container.file).model;
    const own = &c.project.at(container.file).file.tree;
    for (literal.ast.fields) |value| {
        const name = try Model.identifier(c.allocator, tree.tokenSlice(Model.initName(tree, value) orelse continue));
        const field = c.facts.member(container, name) orelse return false;
        if (model.declarations[@backingInt(field.index)].kind != .field) return false;
    }
    for (model.declarations) |decl| {
        if (decl.kind != .field or decl.scope != container.scope) continue;
        if (model.containerField(own, decl.node).?.ast.value_expr != .none) continue;
        for (literal.ast.fields) |value| {
            if (std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(Model.initName(tree, value) orelse continue)), decl.name)) break;
        } else return false;
    }
    return true;
}
/// Whether no library container whose field `name` the rule would read as a backing field
/// (by the kind `typed` gives a value of it, or a kind not known) has every member in
/// `others`: `p.key` read beside `p.value`, and no aegis type whose `value` is backing state
/// has a `key`.
fn noLibraryHolder(c: *Context, name: []const u8, others: []const []const u8) Context.Error!bool {
    const found = try PackageRules.publication(c.facts, Contract.Kind, Contract.library);
    for (found.files) |file| {
        const model = &c.project.at(file).model;
        for (model.declarations) |decl| {
            if (decl.kind != .field or !std.mem.eql(u8, decl.name, name)) continue;
            const holder: Facts.Container = .{ .file = file, .scope = decl.scope };
            switch (try typed(c.facts, .{ .instance = holder }, 0)) {
                .owner => |k| if (try internalField(c, .{ .instance = holder }, k, name) == .no) continue,
                .other => continue,
                .unknown => {},
            }
            for (others) |other| {
                if (c.facts.member(holder, other) == null) break;
            } else return false;
        }
    }
    return true;
}
/// The members other than `name` the file reads of an expression written as `receiver` is: the
/// same declaration reached through the same fields, unwraps, dereferences, `try`s, elements
/// and argument-less calls (`typedAlike`). Zig types each such expression alike, wherever it is
/// written.
fn receiverMembers(c: *Context, tree: *const Ast, receiver: Ast.Node.Index, name: []const u8) Context.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    if (!try typedAlike(c, receiver, receiver, 0)) return names.items;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (Facts.accesses.formOf(tag) != .member) continue;
        const read = (try Facts.accesses.memberRead(c.facts, c.file, @fromBackingInt(@intCast(i)))) orelse continue;
        const holder = read.receiver orelse continue;
        const member = read.name orelse continue;
        if (holder == receiver or std.mem.eql(u8, member, name)) continue;
        if (!try typedAlike(c, holder, receiver, 0)) continue;
        for (names.items) |earlier| {
            if (std.mem.eql(u8, earlier, member)) break;
        } else try names.append(c.allocator, member);
    }
    return names.items;
}
/// Whether `a` and `b` are the same expression to Zig's types (one expression with itself: one
/// `typedAlike` compares): their paths (Facts.accesses.pathOf) take the same steps, a member by
/// the same name, from roots alike. A root is alike where both name one declaration, both `try`
/// alike operands, or both call with no arguments one function through alike callees. Distinct
/// steps, a member whose name is computed, or a root of any other form are not alike.
fn typedAlike(c: *Context, a: Ast.Node.Index, b: Ast.Node.Index, depth: usize) Context.Error!bool {
    if (depth == 16) return false;
    const left = try Facts.accesses.pathOf(c.facts, c.file, a);
    const right = try Facts.accesses.pathOf(c.facts, c.file, b);
    if (left.steps.len != right.steps.len) return false;
    const last = left.steps.len - 1;
    for (left.steps[0..last], right.steps[0..last]) |x, y| {
        if (x.kind != y.kind) return false;
        if (x.kind == .field and !std.mem.eql(u8, x.name orelse return false, y.name orelse return false)) return false;
    }
    switch (left.root) {
        .decl => |declared| return switch (right.root) {
            .decl => |other| std.meta.eql(declared, other),
            .none, .unknown => false,
        },
        .unknown => return false,
        .none => if (right.root != .none) return false,
    }
    const tree = &c.project.at(c.file).file.tree;
    const x = left.steps[last].node;
    const y = right.steps[last].node;
    const form = Facts.accesses.formOf(tree.nodeTag(x));
    if (form != Facts.accesses.formOf(tree.nodeTag(y))) return false;
    switch (form) {
        .tried => return typedAlike(c, tree.nodeData(x).node, tree.nodeData(y).node, depth + 1),
        .call => {
            var x_buffer: [1]Ast.Node.Index = undefined;
            var y_buffer: [1]Ast.Node.Index = undefined;
            const x_call = tree.fullCall(&x_buffer, x).?; // unreachable: the form is a call's
            const y_call = tree.fullCall(&y_buffer, y).?; // unreachable: the form is a call's
            if (x_call.ast.params.len != 0 or y_call.ast.params.len != 0) return false;
            return typedAlike(c, x_call.ast.fn_expr, y_call.ast.fn_expr, depth + 1);
        },
        else => return false,
    }
}
/// Whether `node` is a type, whose members are declarations and never a value's fields: a
/// container named as such, or a parameter or constant declared `type` (`V.maximum` of a
/// `comptime V: type`).
fn typeValue(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    if (try c.facts.resolve(c.file, node) == .container) return true;
    const tree = try c.project.syntax(try c.source());
    const declared = switch (try c.facts.definition(c.file, node)) {
        .decl => |decl| decl,
        .none, .unknown => return false,
    };
    const decl = c.project.at(declared.file).model.declarations[@backingInt(declared.index)];
    if (declared.file != c.file) return false;
    const written = if (decl.kind == .parameter) decl.node else if (tree.fullVarDecl(decl.node)) |v| v.ast.type_node.unwrap() orelse return false else return false;
    return c.facts.typeIsType(c.file, written);
}

/// Whether `field` (`x.name`, a backing field's name) cannot be an aegis owner's backing field,
/// whatever `x` is, because of what the program does with it. For every published type with a
/// backing field of that name, one of: the program reads a member of `x.name` that the field's
/// declared type lacks (`o.state.storage` is no atomic's), or `x` is a variable whose literal
/// initializer names a field the type lacks (`.{ .state = 0, .base = io }`), or the program
/// reads a member of `x` itself, anywhere in the file, that the type lacks (`p.key` beside
/// `p.value`: `x` is the same expression, so of the same type, wherever it is written). Undecided
/// when any such type is not refuted.
fn refuted(c: *Context, field: Ast.Node.Index, name: []const u8) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    const model = &c.project.at(c.file).model;
    // What the program reads of `x.name`.
    var member: ?[]const u8 = null;
    // Whether the program calls `x.name(...)`: a method, or a field that holds a function.
    var called = false;
    const use = try Facts.accesses.useOf(c.facts, c.file, field);
    // Whether the program uses `x.name` as a truth value, a number or an operand of a comparison.
    const operand = scalarOperand(tree, use);
    switch (use) {
        // By name: what `x` holds does not resolve.
        .member => |read| member = (try Facts.accesses.pathOf(c.facts, c.file, read)).steps[0].name,
        .callee => called = true,
        else => {},
    }
    // The fields `x`'s literal initializer names.
    var literal_buffer: [2]Ast.Node.Index = undefined;
    var literal: ?Ast.full.StructInit = null;
    const receiver = tree.nodeData(field).node_and_token[0];
    const local: ?Model.Declaration.Id = switch (try c.facts.definition(c.file, receiver)) {
        .decl => |decl| if (decl.file == c.file) decl.index else null,
        .none, .unknown => null,
    };
    if (local) |index| {
        if (tree.fullVarDecl(model.declarations[@backingInt(index)].node)) |v| if (v.ast.init_node.unwrap()) |init| {
            if (tree.fullStructInit(&literal_buffer, init)) |value| if (value.ast.type_expr == .none) {
                literal = value;
            };
        };
    }
    const siblings = try receiverMembers(c, tree, receiver, name);
    if (siblings.len != 0 and try noLibraryHolder(c, name, siblings)) return true;
    if (member == null and literal == null and !operand and !called) return false;
    const found = try PackageRules.publication(c.facts, Contract.Kind, Contract.library);
    var any = false;
    for (found.entries) |entry| {
        if (!among(entry.internal, name)) continue;
        // A type function whose containers are known: each is an entry of its own (`Facts.publication`).
        if (entry.target == .function) if (try c.facts.template(entry.target.function)) |made| if ((try Facts.returnedContainers(c.allocator, made)).len != 0) continue;
        const container = (try publishedContainer(c, entry.target)) orelse return false;
        // A published type of this kind without such a field is no candidate.
        const decl = c.facts.member(container, name) orelse continue;
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        if (record.kind != .field) continue;
        any = true;
        if (literal) |value| {
            const lacks = for (value.ast.fields) |init| {
                const label = try Model.identifier(c.allocator, tree.tokenSlice(Model.initName(tree, init) orelse continue));
                const named = c.facts.member(container, label) orelse break true;
                if (c.project.at(named.file).model.declarations[@backingInt(named.index)].kind != .field) break true;
            } else false;
            if (lacks) continue;
        }
        const written = &c.project.at(decl.file).file.tree;
        const type_expr = c.project.at(decl.file).model.containerField(written, record.node).?.ast.type_expr.unwrap() orelse return false;
        // A call needs a function: no backing field of this type holds one.
        if (called) {
            if (callable(try c.facts.resolve(decl.file, type_expr), 0)) return false;
            continue;
        }
        if (member == null and !operand) return false;
        const declared = try c.facts.resolve(decl.file, type_expr);
        if (member) |read| {
            // An array, a slice or a number has no members but a length (and a slice's pointer).
            const sequence = std.mem.eql(u8, read, "len") or std.mem.eql(u8, read, "ptr");
            // Written as a slice or an array, whatever its element is.
            const slice = if (written.fullPtrType(type_expr)) |ptr| ptr.size == .slice else false;
            if (slice or written.fullArrayType(type_expr) != null) {
                if (sequence) return false;
                continue;
            }
            // A type chosen per build (a Debug-only witness): no choice has the member.
            if (declared == .alternatives) {
                for (declared.alternatives) |one| switch (one) {
                    .container, .instance => |held| if (c.facts.member(held, read) != null) return false,
                    .alternatives => unreachable, // unreachable: choose never nests alternatives
                    else => return false,
                };
                continue;
            }
            const holder = switch (declared) {
                .container, .instance => |held| held,
                .array => if (sequence) return false else continue,
                .primitive, .scalar => continue,
                .pointer => |to| switch (to.child.*) {
                    .container, .instance => |held| held,
                    .array, .primitive, .scalar => if (sequence) return false else continue,
                    // A pointer to a choice of types: not refuted by one of them.
                    .alternatives => return false,
                    else => return false,
                },
                .alternatives => unreachable, // unreachable: a choice of types is read above
                else => return false,
            };
            if (c.facts.member(holder, read) != null) return false;
        } else {
            // A struct (not packed) is no truth value, number or comparable operand: an
            // atomic, a mutex or a condition used as one is not this field.
            const held = switch (declared) {
                .container, .instance => |held| held,
                // A choice of types: not refuted by one of them.
                .alternatives => return false,
                else => return false,
            };
            if (!plainStruct(c, held)) return false;
        }
    }
    return any;
}

/// Whether a field's declared type can hold something callable: a function, a pointer to one,
/// or a type that does not resolve (a generic payload can be a function pointer).
fn callable(value: Facts.Value, depth: usize) bool {
    if (depth == 16) return true;
    return switch (value) {
        .container, .instance, .primitive, .array, .scalar, .error_set, .error_union => false,
        .pointer => |inner| callable(inner.child.*, depth + 1),
        .optional => |inner| callable(inner.*, depth + 1),
        .alternatives => |each| for (each) |one| {
            if (callable(one, depth + 1)) break true;
        } else false,
        else => true,
    };
}

/// Whether a value used as `use` (accesses.useOf) is a truth value (an `if`'s or `while`'s
/// condition with no capture, a part of `and`, `or` or `!`), an operand of a comparison or of an
/// operator: each a use no struct's value has.
fn scalarOperand(tree: *const Ast, use: Facts.accesses.Use) bool {
    return switch (use) {
        .logic, .compared, .operand => true,
        .tested => |at| if (tree.fullIf(at)) |full|
            full.payload_token == null and full.error_token == null
        else if (tree.fullWhile(at)) |full|
            full.payload_token == null and full.error_token == null
        else
            false,
        else => false,
    };
}

/// Whether a container is a struct with no packed layout (or an opaque): a type no
/// comparison, arithmetic or condition accepts.
fn plainStruct(c: *Context, container: Facts.Container) bool {
    const model = &c.project.at(container.file).model;
    const tree = &c.project.at(container.file).file.tree;
    const node = model.scopes[@backingInt(container.scope)].node;
    if (node == .root) return true;
    var buffer: [2]Ast.Node.Index = undefined;
    const full = tree.fullContainerDecl(&buffer, node) orelse return false;
    return switch (tree.tokenTag(full.ast.main_token)) {
        .keyword_struct => if (full.layout_token) |layout| tree.tokenTag(layout) != .keyword_packed else true,
        .keyword_opaque => true,
        else => false,
    };
}

/// The container a published target is: the type itself, or the one a type function returns,
/// the first container declared in its body.
fn publishedContainer(c: *Context, target: PackageRules.Target) Context.Error!?Facts.Container {
    switch (target) {
        .container => |container| return container,
        .function => |function| {
            if (try c.facts.template(function)) |made| switch (made) {
                .container, .instance => |container| return container,
                // A choice of made types is no one container: the body's first is read.
                .alternatives => {},
                else => {},
            };
            const model = &c.project.at(function.file).model;
            const tree = &c.project.at(function.file).file.tree;
            const record = model.declarations[@backingInt(function.index)];
            const whole = if (tree.nodeTag(record.node) == .fn_decl) record.node else model.parentOf(record.node) orelse return null;
            for (model.scopes, 0..) |scope, i| {
                if (scope.kind != .container) continue;
                var at = scope.parent;
                while (at) |p| : (at = model.scopes[@backingInt(p)].parent) {
                    if (model.scopes[@backingInt(p)].kind == .container) break;
                    if (model.scopes[@backingInt(p)].kind == .function) {
                        if (model.scopes[@backingInt(p)].node == whole or model.scopes[@backingInt(p)].node == record.node) return .{ .file = function.file, .scope = @fromBackingInt(@intCast(i)) };
                        break;
                    }
                }
            }
            return null;
        },
    }
}

/// Whether a name is a field only aegis touches (A001's): yes, no, or undecided.
const Internal = enum { yes, no, unknown };
/// Whether `name` is a field only aegis touches of `holder`, whose role is `k`: its type's own
/// `.internal`, as aegis declares it, for each type aegis gives a role that it may be. Where
/// only the role is known, glint does not know which of that role's types it is: a field every
/// one of them keeps is one, a field only some keep is undecided, a field none keeps is not.
fn internalField(c: *Context, holder: Facts.Value, k: Contract.Kind, name: []const u8) Context.Error!Internal {
    var every = true;
    var some = false;
    const types = try holderInternals(c, holder);
    if (types.len != 0) {
        for (types) |own| if (among(own, name)) {
            some = true;
        } else {
            every = false;
        };
    } else {
        const found = try PackageRules.publication(c.facts, Contract.Kind, Contract.library);
        for (found.entries) |entry| {
            if (@as(Contract.Kind, @fromBackingInt(@intCast(entry.role))) != k) continue;
            if (among(entry.internal, name)) some = true else every = false;
        }
    }
    return if (!some) .no else if (every) .yes else .unknown;
}
/// Whether `holder`, whose role is `k`, keeps any field only aegis touches: by its type's own
/// `.internal`, or where only the role is known, yes where every type of that role keeps one,
/// undecided where only some do.
fn keepsInternal(c: *Context, holder: Facts.Value, k: Contract.Kind) Context.Error!Internal {
    var every = true;
    var some = false;
    const types = try holderInternals(c, holder);
    if (types.len != 0) {
        for (types) |own| if (own.len != 0) {
            some = true;
        } else {
            every = false;
        };
    } else {
        const found = try PackageRules.publication(c.facts, Contract.Kind, Contract.library);
        for (found.entries) |entry| {
            if (@as(Contract.Kind, @fromBackingInt(@intCast(entry.role))) != k) continue;
            if (entry.internal.len != 0) some = true else every = false;
        }
    }
    return if (!some) .no else if (every) .yes else .unknown;
}
/// The `.internal` lists of the aegis types `holder` may be (through pointers, optionals and error
/// unions, each choice of a per-build or comptime choice): empty where none of them is one aegis
/// gives a role.
fn holderInternals(c: *Context, holder: Facts.Value) Context.Error![]const []const []const u8 {
    var found: std.ArrayList([]const []const u8) = .empty;
    var pending: std.ArrayList(Facts.Value) = .empty;
    try pending.append(c.allocator, holder);
    while (pending.pop()) |each| switch (each) {
        .pointer => |inner| try pending.append(c.allocator, inner.child.*),
        .optional, .error_union => |inner| try pending.append(c.allocator, inner.*),
        .alternatives => |choices| try pending.appendSlice(c.allocator, choices),
        else => if (try PackageRules.internalOf(c.facts, Contract.Kind, Contract.library, each)) |own| try found.append(c.allocator, own),
    };
    return found.items;
}
/// Whether `name` is a field only aegis touches of any type aegis gives a role.
fn anyInternal(c: *Context, name: []const u8) Context.Error!bool {
    const found = try PackageRules.publication(c.facts, Contract.Kind, Contract.library);
    for (found.entries) |entry| if (among(entry.internal, name)) return true;
    return false;
}

fn requiredOwner(c: *Context, node: Ast.Node.Index, rule: Rule, token: Ast.TokenIndex) Context.Error!?Contract.Kind {
    switch (try ownerKind(c, node, rule)) {
        .owner => |k| return k,
        .other => return null,
        // Unresolved, it may be an owner the program's own function returns, whatever aegis
        // declares.
        .unknown => {
            const tree = try c.project.syntax(try c.source());
            try c.undecided(rule, tree.tokenStart(token), .unresolved, "candidate receiver/value has no resolved operation contract");
            return null;
        },
    }
}
/// What owner `node` is for `rule`: its contract's, or what its type reads as.
fn ownerKind(c: *Context, node: Ast.Node.Index, rule: Rule) Context.Error!Typed {
    if (try Contract.owner(c, node)) |k| return .{ .owner = k };
    const value = try c.facts.resolve(c.file, node);
    _ = rule;
    // A type chosen at compile time is one type per build: an operation on it is the
    // owner's in the builds that choose the owner.
    return perBuild(c, value);
}
const Typed = union(enum) { owner: Contract.Kind, other, unknown };
/// Two readings of what parts or alternatives hold, as one: unknown stays unknown, one owner
/// kind among plain types is that kind's, two kinds are unknown.
fn joined(found: Typed, next: Typed) Typed {
    return switch (found) {
        .unknown => .unknown,
        .other => next,
        .owner => |k| switch (next) {
            .other => found,
            .owner => |other| if (other == k) found else .unknown,
            .unknown => .unknown,
        },
    };
}
/// What a value is in the builds that choose among types: the one published kind its
/// alternatives are, the rest plain types, decided as that kind; any unknown alternative, or
/// two kinds, leave it unknown.
fn perBuild(c: *Context, value: Facts.Value) Context.Error!Typed {
    var current = value;
    while (true) current = switch (current) {
        .pointer => |payload| payload.child.*,
        .array, .optional, .error_union => |payload| payload.*,
        .reified => |built| built.fields.*,
        .alternatives => break,
        else => break,
    };
    if (current != .alternatives) return typed(c.facts, value, 0);
    var found: Typed = .other;
    for (current.alternatives) |one| found = joined(found, try typed(c.facts, one, 0));
    return found;
}
/// What a copy of a value of a binding's type duplicates, per build as `perBuild` reads it: a
/// pointer in it, or in an array of them, is an alias, which A002 leaves out.
fn copied(c: *Context, value: Facts.Value, depth: usize) Context.Error!Typed {
    if (depth == 64) return .unknown;
    return switch (value) {
        .pointer => .other,
        .array, .optional, .error_union => |payload| copied(c, payload.*, depth + 1),
        .reified => |built| copied(c, built.fields.*, depth + 1),
        // Each part a copy of its own, per build as well.
        .literal => |literal| blk: {
            var found: Typed = .other;
            for (try c.facts.literalParts(literal)) |part| found = joined(found, try copied(c, part, depth + 1));
            break :blk found;
        },
        .alternatives => |each| blk: {
            var found: Typed = .other;
            for (each) |one| found = joined(found, try copied(c, one, depth + 1));
            break :blk found;
        },
        // A record of the program copied copies what it holds by value in its fields
        // (`struct { s: Secret(u32) }`), as `heldInRecord` reads them for A003.
        .instance => |container| blk: {
            const found = try typed(c.facts, value, depth + 1);
            if (found != .other) break :blk found;
            break :blk recordCopied(c, container, depth + 1);
        },
        else => typed(c.facts, value, depth + 1),
    };
}
/// What a copy of a value of the program's record `container` duplicates of its fields, by
/// `copied`. aegis's own types hold what their contract says; std's records are std's.
fn recordCopied(c: *Context, container: Facts.Container, depth: usize) Context.Error!Typed {
    if (try c.inLibrary(Contract.library, container.file)) return .other;
    if (!try c.facts.program(container.file)) return .other;
    var found: Typed = .other;
    for (try c.facts.heldFields(container)) |field| {
        // A field typed only by a generic's binding is judged where that is bound.
        if (bindingTyped(field.value)) continue;
        found = joined(found, try copied(c, field.value, depth + 1));
    }
    return found;
}
/// What a resolved value's type says: a published aegis type, a type that is not aegis, or
/// unknown. A guarded owner's guard is the guard. Another type declared inside a published one
/// and not in the contract is plain data, as an unlisted type at a module's top is: the
/// contract lists every type whose fields are private state (`Budget.Reservation`,
/// `Table.Scope`), and the state such a type holds for its owner (a map's entries, a shared
/// owner's block) is reached through the owner's backing field, which is read there. A choice
/// between types that disagree stays unknown.
fn typed(facts: *Facts, value: Facts.Value, depth: usize) Facts.ResolveError!Typed {
    if (depth == 64) return .unknown;
    return switch (value) {
        // What std computes from the program and target it is in is std's own: std declares
        // no aegis type, so it plays no aegis role. Code the build does not compile holds none.
        .unknown => |why| switch (why) {
            .zig_own, .absent => .other,
            else => .unknown,
        },
        .pointer => |payload| typed(facts, payload.child.*, depth + 1),
        .array, .optional, .error_union => |payload| typed(facts, payload.*, depth + 1),
        // A built type holds what its fields' types do.
        .reified => |built| typed(facts, built.fields.*, depth + 1),
        .alternatives => |each| blk: {
            const first = try typed(facts, each[0], depth + 1);
            for (each[1..]) |one| if (!std.meta.eql(first, try typed(facts, one, depth + 1))) break :blk .unknown;
            break :blk first;
        },
        // An anonymous literal holds what its fields or elements do: one owner among plain
        // parts is that owner's, as a copy of the literal copies it.
        .literal => |literal| blk: {
            var found: Typed = .other;
            for (try facts.literalParts(literal)) |part| found = joined(found, try typed(facts, part, depth + 1));
            break :blk found;
        },
        // A guard and its hand-off among them, by the roles aegis declares (`Guarded(T).Guard`).
        .container, .instance => if (try PackageRules.role(facts, Contract.Kind, Contract.library, value)) |k| .{ .owner = k } else .other,
        else => .other,
    };
}
/// Whether a value is unknown only because a generic's binding gives its type.
fn bindingTyped(value: Facts.Value) bool {
    var current = value;
    while (true) current = switch (current) {
        .pointer => |inner| inner.child.*,
        .array, .optional, .error_union => |inner| inner.*,
        .unknown => |why| return why == .generic,
        // A choice of types is the binding's only where each of them is.
        .alternatives => |each| {
            for (each) |one| if (!bindingTyped(one)) return false;
            return each.len != 0;
        },
        else => return false,
    };
}

/// A call binding a generic's type or `anytype` parameter whose values the generic copies
/// (there or in what it passes them on to): a finding where the binding is a recognized owner,
/// reported here, at the binding, naming the copy. An `anytype` parameter is bound to its
/// argument's value. A binding that does not resolve is undecided; one a generic of this
/// file's own gives is decided where that one is bound. For A003, a local the generic acquires
/// by a function of its type parameter (`var h = Hash.init(.{});`): a binding to a plain type
/// owes nothing; one to an owner with a release leaves the binding undecided, as the generic's
/// paths are not walked per binding.
fn checkBinding(c: *Context, tree: *const Ast, node: Ast.Node.Index, rule: Rule) Context.Error!void {
    const call = (try Facts.calls.at(c.facts, c.file, node)) orelse return;
    // The callee as written, where a finding is reported: a name (`f(x)`) or a member (`x.f()`,
    // `T.f(x)`).
    const path = try Facts.accesses.pathOf(c.facts, c.file, call.callee_expr);
    const name_token = switch (path.steps[0].kind) {
        .root => (c.project.at(c.file).model.reference(path.steps[0].node) orelse return).token,
        .field => if (path.steps[0].name == null) return else tree.lastToken(path.steps[0].node),
        .index, .slice, .unwrap, .deref => return,
    };
    // What the callee does with its parameters, by what it resolves to: each function it may
    // call (an alias is the function it names). One that does not resolve, called as a member
    // (`x.f()` on a holder of no known type), is any function of the run so named, joined over
    // all of them; called by a name (`f(x)`, `f` a value of no known function), it may be any.
    const copying: Facts.Copies = switch (call.callee) {
        .function => |function| try c.facts.copiesOf(function),
        .choice => |each| joined: {
            var some: Facts.Copies = .none;
            for (each) |function| switch (try c.facts.copiesOf(function)) {
                .none => {},
                .moves => if (some == .none) {
                    some = .moves;
                },
                .copies => break :joined .copies,
            };
            break :joined some;
        },
        .any => if (path.steps[0].kind == .field) try c.facts.copiesNamed(c.file, path.steps[0].node) else .copies,
    };
    switch (copying) {
        .none => return,
        // A generic that only moves a parameter into storage copied for A002 alone (removed).
        .moves => return,
        .copies => {},
    }
    // Each function it may call is bound by it; a callee spelled as a copying generic that
    // does not resolve may be one.
    const functions: []const Facts.Decl = switch (call.callee) {
        .function => |function| &.{function},
        .choice => |each| each,
        .any => {
            // A call through a function pointer (`rule.check(&context)`): no generic, whose
            // parameters a runtime function's type cannot take, is called there.
            const callee = try c.facts.resolve(c.file, call.callee_expr);
            if (callee == .fn_type or (callee == .pointer and callee.pointer.child.* == .fn_type)) return;
            // Whatever function it calls, a binding reports only an argument `boundBy` does not
            // pass over: one neither the receiver, a parameter of a generic this call is in
            // (decided where that is bound), nor plain data (`access.write(n)`, `n: u64`).
            if (!try anyArgumentBinds(c, call)) return;
            return c.undecided(rule, tree.tokenStart(name_token), .unresolved, "a call spelled as a generic that copies its parameters does not resolve: its binding may copy an owner");
        },
    };
    // A method call's receiver is its first parameter (`boundBy` reads the known arguments).
    switch (call.args) {
        .known => {},
        .unknown => |why| return c.undecided(rule, tree.tokenStart(name_token), if (why == .budget) .budget_exhausted else .unresolved, "a call spelled as a generic that copies its parameters may or may not bind its receiver: its binding may copy an owner"),
    }
    for (functions) |function| if (try boundBy(c, tree, call, rule, function, name_token)) return;
}

/// Whether the cast a generic makes by its parameter's type reads a scalar's integer out (a
/// call of `raw`, `@backingInt`, `@intFromEnum`, `@call` of `raw`, or `@bitCast`/`@ptrCast` of
/// the value it is given), where the others make an integer into the bound type.
fn readOut(c: *Context, copy: Facts.ParameterCopy) bool {
    const tree = &c.project.at(copy.site.file).file.tree;
    const name = Facts.builtinName(tree, copy.site.node) orelse return true;
    if (std.mem.eql(u8, name, "@backingInt") or std.mem.eql(u8, name, "@intFromEnum") or std.mem.eql(u8, name, "@call")) return true;
    if (!std.mem.eql(u8, name, "@bitCast") and !std.mem.eql(u8, name, "@ptrCast")) return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, copy.site.node, &buffer);
    const source = copy.source orelse return false;
    return args.len == 1 and source.node == args[0];
}

/// Whether the integer read out at `node` is operated on as `checkScalar` reports a raw value:
/// an operator's or a comparison's operand, the argument of a cast or of integer arithmetic, or
/// carried unchanged (`@as`, a grouping, `try`) or through a local it initializes or is stored
/// into, to one. An index, an argument, a store into a place other than a local and a return
/// are its exit. A use not read here, or a chain too deep to follow, may be one.
fn readOutOperated(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!bool {
    if (depth > 6) return true;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    switch (try Facts.accesses.useOf(c.facts, file, node)) {
        // A compound assignment reads its target: `n += 1` computes on what `n` holds.
        .compared, .updated, .unknown, .address, .in_asm => return true,
        // A `for` range's bound counts iterations, as in a function of no generic.
        .operand => |by| return tree.nodeTag(by) != .for_range,
        .carried => |carry| return readOutOperated(c, file, carry.into, depth + 1),
        .builtin_argument => |arg| {
            const name = Facts.builtinName(tree, arg.call) orelse return true;
            if (listed(name, &scalar_casts) or listed(name, &scalar_arithmetic)) return true;
            // The integer unchanged, or reinterpreted: what holds the result holds it.
            if (std.mem.eql(u8, name, "@as") or std.mem.eql(u8, name, "@splat") or std.mem.eql(u8, name, "@ptrCast")) return readOutOperated(c, file, arg.call, depth + 1);
            return false;
        },
        .initializes => |declared| {
            for (model.declarations) |decl| if (decl.node == declared and decl.kind == .variable) return localOperated(c, file, decl, depth);
            return true;
        },
        .stored => |store| {
            const target = store.target orelse return true;
            const path = try Facts.accesses.pathOf(c.facts, file, target);
            // Stored into a field or an element: the place's own type reads it from there.
            if (path.steps.len != 1) return false;
            const ref = model.reference(path.steps[0].node) orelse return true;
            const index = ref.declaration orelse return true;
            const decl = model.declarations[@backingInt(index)];
            if (decl.kind != .variable) return false;
            return localOperated(c, file, decl, depth);
        },
        else => return false,
    }
}

/// Whether a variable holding an integer read out is operated on where it is read. One a
/// container declares may be read in another file: it may be.
fn localOperated(c: *Context, file: Project.FileId, decl: Model.Declaration, depth: u8) Context.Error!bool {
    const model = &c.project.at(file).model;
    switch (model.scopes[@backingInt(decl.scope)].kind) {
        .file, .container => return true,
        else => {},
    }
    var each = Mentions.all(model, decl.token);
    while (each.next()) |name| switch (try Facts.accesses.useOf(c.facts, file, name)) {
        .written => {},
        else => if (try readOutOperated(c, file, name, depth + 1)) return true,
    };
    return false;
}

/// Whether some argument of `call`, whose callee does not resolve, is one a binding of any
/// function may report (`boundBy`): not the receiver it binds, a parameter of a generic the call
/// is in, nor of a type that resolves to no owner. A receiver that may bind or not (`access.write(n)`,
/// `access` of no known type) passes the written arguments either way, its holder bound as
/// written or not passed: those are read. `@call` given no tuple literal may pass any.
fn anyArgumentBinds(c: *Context, call: Facts.calls.Call) Context.Error!bool {
    var buffer: [1]Ast.Node.Index = undefined;
    const tree = &c.project.at(c.file).file.tree;
    const args = switch (call.args) {
        .known => |each| each,
        .unknown => if (call.receiver == .unknown) (tree.fullCall(&buffer, call.node) orelse return true).ast.params else return true,
    };
    for (args, 0..) |argument, position| {
        if (call.receiver == .bound and position == 0) continue;
        if (c.facts.fromParameter(c.file, argument)) continue;
        // Of a type that resolves to no owner, in any build (`n`, `@as(u8, 3)`, `u8`): what a
        // binding to it copies, casts or makes is plain, as `boundBy` judges it. Which
        // parameter takes a type is not known here, so a type stands for its values
        // (`aegis.Secret(u32)`, which a written reading would take as plain `type`).
        // A record holding an owner in a field is no plain data: copying it copies the owner.
        const value = try instanceOf(c, try c.facts.resolve(c.file, argument));
        if (try perBuild(c, value) != .other or try copied(c, value, 0) != .other) return true;
    }
    return false;
}

/// `checkBinding` of `function`, one `call` may call, its arguments known: whether it reported
/// a copy.
fn boundBy(c: *Context, tree: *const Ast, call: Facts.calls.Call, rule: Rule, function: Facts.Decl, name_token: Ast.TokenIndex) Context.Error!bool {
    const node = call.node;
    const args = call.args.known;
    const receiver = call.receiver == .bound;
    const made = try c.facts.parameterCopies(function);
    if (made.len == 0) return false;
    const written = &c.project.at(function.file).file.tree;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = written.fullFnProto(&proto_buffer, c.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return false;
    // Which parameters take a type: a binding of one is a type the call writes.
    var types: [64]bool = @splat(false);
    var values: [64]bool = @splat(false);
    var count: usize = 0;
    var it = proto.iterate(written);
    while (it.next()) |param| : (count += 1) {
        if (count == types.len) {
            try c.undecided(rule, tree.tokenStart(name_token), .unsupported, "a generic of more parameters than are read here copies some: its binding may copy an owner");
            return false;
        }
        types[count] = if (param.type_expr) |t| try typeKeyword(c, function.file, t) == true else false;
        values[count] = param.anytype_ellipsis3 != null;
    }
    // The generic's casts this binding makes an aegis scalar's: one finding at the binding,
    // naming each, however many of the generic's paths and instances reach it.
    var casts: std.ArrayList(Report.Span) = .empty;
    for (args, 0..) |argument, position| {
        if (position == count) break;
        // The receiver is bound as written, never a type or a value the call writes for it.
        if ((receiver and position == 0) or (!types[position] and !values[position])) continue;
        // A parameter of a generic this call is in, passed on: decided where that is bound.
        if (c.facts.fromParameter(c.file, argument)) continue;
        // An argument left undecided is one site of the binding, however many of the
        // generic's copies read it: reported once, at its first.
        var reported = false;
        for (made) |copy| {
            if (copy.position != position) continue;
            // A cast by a parameter's type is A004's; a copy A002's, an acquisition A003's.
            if ((copy.kind == .cast) != (rule == scalar)) continue;
            // A copy was A002's and an acquisition A003's (both removed): only casts remain.
            if (copy.kind != .cast) continue;
            // A parameter the generic moves into storage (`out.* = x`): the argument moves there
            // where it is made in place, or is a local nothing holds beside the call (`moved`); a
            // live local read again, or one passed on each pass of a loop, is copied.
            if (copy.kind == .moved) {
                const parts = try c.facts.copiedParts(c.file, argument);
                var moves = parts.deep == null;
                for (parts.places) |place| if (try moved(c, argument, place, false) != .yes) {
                    moves = false;
                };
                if (moves) continue;
            }
            // What the generic passes on of the argument (what calling it returns, what it points
            // to), read with this call's bindings; else the argument, plain data as written (a type
            // of numbers, and pointers or arrays of them, or a value of one) or as it resolves.
            const value = if (copy.source != null)
                (try c.facts.boundCopy(call, function, copy)) orelse continue
            else if (copy.crowded)
                Facts.Value{ .unknown = .budget }
            else if (if (types[position]) try plainType(c, c.file, argument, 0) else try plainValue(c, c.file, argument, 0))
                continue
            else
                try c.facts.resolve(c.file, argument);
            if (copy.kind == .cast) {
                // The library's own generics are its safe types' internals.
                if (try c.inLibrary(Contract.library, copy.site.file)) continue;
                // A scalar's integer read out (`raw()`, `@backingInt`, the bits of its value) is
                // its exit, as in a function of no generic: the binding makes it a finding only
                // where that integer is operated on (`readOutOperated`).
                if (readOut(c, copy) and !try readOutOperated(c, copy.site.file, copy.site.node, 0)) continue;
                switch (try perBuild(c, try instanceOf(c, value))) {
                    .owner => |k| if (k == .scalar) {
                        const span = c.spanOf(copy.site.file, c.project.at(copy.site.file).file.tree.nodeMainToken(copy.site.node));
                        for (casts.items) |known| {
                            if (known.file == span.file and known.start == span.start) break;
                        } else try casts.append(c.allocator, span);
                    },
                    .other => {},
                    .unknown => if (!bindingTyped(value)) try undecidedOnce(c, &reported, scalar, tree.tokenStart(tree.nodeMainToken(node)), "a generic that casts integers by its parameter's type is bound to a type that does not resolve"),
                }
                continue;
            }
        }
    }
    return castsReported(c, tree, node, casts.items);
}

/// `boundBy`'s `casts` of a binding at `node`, reported as one finding naming each: whether there
/// were any.
fn castsReported(c: *Context, tree: *const Ast, node: Ast.Node.Index, casts: []const Report.Span) Context.Error!bool {
    if (casts.len == 0) return false;
    var named: std.ArrayList(u8) = .empty;
    for (casts, 0..) |span, i| {
        if (i != 0) try named.appendSlice(c.allocator, if (i + 1 == casts.len) " and " else ", ");
        try named.print(c.allocator, "{s}:{d}", .{ c.project.at(span.file).input.name, span.line });
    }
    const message = if (casts.len == 1)
        try c.allocator.print("this binding makes the integer {s} makes or reads by the generic's type an aegis scalar's, outside its checked construction and arithmetic", .{named.items})
    else
        try c.allocator.print("this binding makes the integers {s} make or read by the generic's type aegis scalars', outside their checked construction and arithmetic", .{named.items});
    const at = tree.tokenToSpan(tree.nodeMainToken(node));
    try c.emitRelated(scalar, at.start, at.end, message, casts);
    return true;
}

/// Reports `rule`'s undecided binding of an argument at `at`, where `reported` says none has been.
fn undecidedOnce(c: *Context, reported: *bool, rule: Rule, at: u32, detail: []const u8) Context.Error!void {
    if (reported.*) return;
    reported.* = true;
    try c.undecided(rule, at, .unresolved, detail);
}

/// Whether `node` is a name (the model's reference), never a decl literal's (`.init`).
fn isName(model: *const Model, node: Ast.Node.Index) bool {
    const ref = model.reference(node) orelse return false;
    return ref.unknown != .literal_context;
}

/// The name a place is read through (`s` of `s`, `h.s`, `@field(h, "s")`, `p.*`, `a[0]`,
/// `a[0..1].*`, `o.?`), or null for a value made in place (a call, a literal, an operator),
/// which no other holder shares.
fn placeRoot(c: *Context, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const path = try Facts.accesses.pathOf(c.facts, c.file, node);
    const root = path.steps[path.steps.len - 1].node;
    return if (isName(&c.project.at(c.file).model, root)) root else null;
}

/// What a place read off a call's result is read through, where the call gives a pointer
/// another holder shares (`it.next().?.*`, `map.getPtr(k).?.owner`): the call, standing for
/// the place's root. Null where every step reads the value the call makes, which no other
/// holder shares; a step whose operand does not resolve may be through a pointer.
fn sharedReturn(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const path = try Facts.accesses.pathOf(c.facts, c.file, node);
    var shared = false;
    for (path.steps[0 .. path.steps.len - 1], path.steps[1..]) |place, below| switch (place.kind) {
        .deref => shared = true,
        // A field or an element read through a pointer dereferences it.
        .field, .index, .slice => switch (try c.facts.resolve(c.file, below.node)) {
            .pointer, .unknown => shared = true,
            // Through a pointer where any build's operand is one.
            .alternatives => |each| for (each) |one| {
                if (one == .pointer or one == .unknown) shared = true;
            },
            else => {},
        },
        .unwrap, .root => {},
    };
    // A type's member (`@TypeOf(x).Role`): no value is read.
    const root = path.steps[path.steps.len - 1].node;
    return if (shared and !typeBuiltin(tree, root)) root else null;
}

/// Whether `node` is a builtin call that gives a type.
fn typeBuiltin(tree: *const Ast, node: Ast.Node.Index) bool {
    // A module's or Zig file's namespace; a ZON file's value is none.
    if (Facts.importKind(tree, node)) |kind| return kind == .namespace;
    for ([_][]const u8{ "@TypeOf", "@This", "@typeInfo", "@Type", "@FieldType" }) |name| {
        if (Facts.isBuiltin(tree, node, name)) return true;
    }
    return false;
}

/// Whether `copy` moves `source`, a local or a capture of the function, rather than
/// duplicating it. The source is the function's own: a variable of a block, or a capture of a
/// value made in place (a capture of a place copies what stays there), or of a local the
/// capture itself moves. Nothing holds it beside the copy: no read before the copy took a
/// copy of it or a part of it that may be an owner (an argument, a literal's part, a
/// method's receiver by value), and no `defer` or `errdefer` reads it after. For a declaration
/// or an assignment, nothing reads it after the copy, no address of it or of a part was taken
/// before (it may be kept, and reach the source after), and no loop runs the copy again without
/// declaring the source again. For a `return`, the function's locals end with it: a later read
/// is on another path, unless a loop the return is in runs it first.
fn moved(c: *Context, copy: Ast.Node.Index, source: Ast.Node.Index, returned: bool) Context.Error!Is {
    const tree = try c.project.syntax(try c.source());
    const model = &c.project.at(c.file).model;
    const index = Contract.local(c, source) orelse return .no;
    const decl = model.declarations[@backingInt(index)];
    // Why it may be held beside the copy, where nothing is known to hold it.
    var unknown: ?Facts.Unknown = null;
    switch (decl.kind) {
        .variable => if (model.scopes[@backingInt(decl.scope)].kind != .block) return .no,
        .capture => switch (try capturedMoved(c, decl.node)) {
            .yes => {},
            .no => return .no,
            .unknown => |why| unknown = why,
        },
        else => return .no,
    }
    const at = tree.lastToken(copy);
    // The outermost loop the copy is in that the source is declared outside: it runs what
    // follows the copy before the copy again.
    var loop: ?Ast.Node.Index = null;
    var up = model.parentOf(copy);
    while (up) |parent| : (up = model.parentOf(parent)) {
        if (tree.firstToken(parent) <= decl.token and decl.token <= tree.lastToken(parent)) break;
        if (tree.fullWhile(parent) != null or tree.fullFor(parent) != null) loop = parent;
    }
    if (loop != null and !returned) return .no;
    var named_by = Mentions.all(model, model.declarations[@backingInt(index)].token);
    while (named_by.next()) |candidate| {
        if (candidate == source) continue;
        var deferred = false;
        var parents = model.parentOf(candidate);
        while (parents) |parent| : (parents = model.parentOf(parent)) {
            switch (tree.nodeTag(parent)) {
                .@"defer", .@"errdefer" => deferred = true,
                else => {},
            }
        }
        if (deferred) return .no;
        const token = tree.nodeMainToken(candidate);
        if (token > at) {
            if (!returned) return .no;
            // After a `return`: another path, unless a loop the return is in runs it before.
            const outer = loop orelse continue;
            if (token > tree.lastToken(outer)) continue;
        }
        switch (try heldBy(c, candidate)) {
            .read => {},
            .copy => return .no,
            // An address taken before a declaration's copy may be kept; a `return` ends what
            // it points at, which A014 reads.
            .address => if (!returned) return .no,
            .unknown => |why| unknown = why,
        }
    }
    return if (unknown) |why| .{ .unknown = why } else .yes;
}

/// Whether a capture's value is moved into it: the value of a call or other value made in
/// place (`if (b.take()) |r|`), or a local nothing reads again after the capture copies it. A
/// capture of a place (`if (h.maybe) |r|`, `for (h.list) |r|`, a switch's operand), or of what
/// a call's pointer or slice reaches (`if (s.slot().*) |r|`, `for (s.held()) |r|`), copies
/// what stays there.
fn capturedMoved(c: *Context, holder: Ast.Node.Index) Context.Error!Is {
    const tree = try c.project.syntax(try c.source());
    const model = &c.project.at(c.file).model;
    var operands: []const Ast.Node.Index = &.{};
    var single: [1]Ast.Node.Index = undefined;
    if (tree.fullIf(holder)) |branch| {
        single = .{branch.ast.cond_expr};
        operands = &single;
    } else if (tree.fullWhile(holder)) |loop| {
        single = .{loop.ast.cond_expr};
        operands = &single;
    } else if (tree.fullFor(holder)) |loop| {
        operands = loop.ast.inputs;
    } else if (tree.fullSwitchCase(holder) != null) {
        const choice = tree.fullSwitch(model.parentOf(holder) orelse return .no) orelse return .no;
        single = .{choice.ast.condition};
        operands = &single;
    } else if (tree.nodeTag(holder) == .@"catch") {
        single = .{tree.nodeData(holder).node_and_node[0]};
        operands = &single;
    } else return .no;
    var unknown: ?Facts.Unknown = null;
    for (operands) |operand| {
        // What the capture copies, as a copy of the operand does (`Facts.copiedParts`): through
        // a branch, `orelse`, `catch`, a labeled block's `break`, `@as`.
        const parts = try c.facts.copiedParts(c.file, operand);
        if (parts.deep != null) unknown = .unsupported;
        for (parts.places) |value| {
            if ((try placeRoot(c, value)) == null) {
                // What a pointer a call gives points at (`s.slot().*`) stays where it is: the
                // capture copies it.
                if (try sharedReturn(c, tree, value) != null) return .no;
                unknown = .unsupported;
                continue;
            }
            // A local moved by the capture: nothing reads it again (a loop's condition reads
            // it each time round).
            if ((try Facts.accesses.pathOf(c.facts, c.file, value)).steps.len != 1) return .no;
            switch (try moved(c, value, value, false)) {
                .yes => {},
                .no => return .no,
                .unknown => |why| unknown = why,
            }
        }
        // A call's value is made in place, moved into the capture; the elements of a slice
        // one gives (`for (s.held()) |g|`) stay where they are: the capture copies them.
        if (tree.fullFor(holder) != null) for (parts.results) |result| switch (try c.facts.resolve(c.file, result)) {
            .pointer => return .no,
            .unknown => |why| unknown = why,
            // A pointer in some builds: copied in those, moved in the rest.
            .alternatives => |each| for (each) |one| switch (one) {
                .pointer => unknown = unknown orelse .unsupported,
                .unknown => |why| unknown = why,
                .alternatives => unreachable, // unreachable: choose never nests alternatives
                else => {},
            },
            else => {},
        };
        // Any other shape, decided by its value's type.
        for (parts.rest) |node| switch (try perBuild(c, try c.facts.resolve(c.file, node))) {
            .other => {},
            .owner, .unknown => unknown = .unsupported,
        };
    }
    return if (unknown) |why| .{ .unknown = why } else .yes;
}

const Hold = union(enum) { read, copy, address, unknown: Facts.Unknown };

/// What a reference to a local, read before a copy of it, does with it: `.read` a plain part
/// or a discard (`r.amount`, `_ = r`, `@TypeOf(r)`); `.address` its address or a part's
/// (`&r`, `&r.amount`), or a method's receiver that takes `*Self`; `.copy` anything else, a
/// copy of all of it or of a part that may be an owner (an argument, a literal's part, a
/// method's receiver by value); `.unknown` a method's receiver whose method does not resolve.
fn heldBy(c: *Context, reference: Ast.Node.Index) Context.Error!Hold {
    const tree = try c.project.syntax(try c.source());
    // The part of the local read: `r`, `r.a`, `r.a[0]`, `r.?`.
    var part = reference;
    var use = try Facts.accesses.useOf(c.facts, c.file, part);
    while (true) {
        part = switch (use) {
            .member => |read| read,
            .element => |indexed| indexed,
            .carried => |carry| switch (carry.how) {
                .grouped, .unwrapped => carry.into,
                else => break,
            },
            else => break,
        };
        use = try Facts.accesses.useOf(c.facts, c.file, part);
    }
    switch (use) {
        .address => return .address,
        // Written over, not read.
        .written => if (part == reference) return .read,
        .discarded => return .read,
        .builtin_argument => |at| for ([_][]const u8{ "@TypeOf", "@sizeOf", "@alignOf" }) |each| {
            if (Facts.isBuiltin(tree, at.call, each)) return .read;
        },
        // A method called on it, or on a part: its receiver.
        .callee => |call| if (Facts.accesses.formOf(tree.nodeTag(part)) == .member) return switch (try pointerReceiver(c, call)) {
            .yes => .address,
            .no => .copy,
            .unknown => |why| .{ .unknown = why },
        },
        else => {},
    }
    if (part == reference) return .copy;
    // A part read: plain data copies no owner.
    if (try plainValue(c, c.file, part, 0)) return .read;
    return switch (try perBuild(c, try c.facts.resolve(c.file, part))) {
        .other => .read,
        else => .copy,
    };
}

/// Whether the method the call at `call` calls (`r.release()`, `r.a.release()`) takes its
/// receiver by pointer: no where it takes it by value or `anytype` (a value); unknown where it
/// may call another (`calledFunction`).
fn pointerReceiver(c: *Context, call: Ast.Node.Index) Context.Error!Is {
    const origin = switch (try calledFunction(c, c.file, call)) {
        .function => |function| function,
        .unknown => |why| return .{ .unknown = why },
    };
    const record = c.project.at(origin.file).model.declarations[@backingInt(origin.index)];
    const written = &c.project.at(origin.file).file.tree;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = written.fullFnProto(&proto_buffer, record.node) orelse return .no;
    var it = proto.iterate(written);
    const first = it.next() orelse return .no;
    const kind = first.type_expr orelse return .no;
    return if (written.fullPtrType(kind) != null) .yes else .no;
}

/// The function the call at `node` calls (`Facts.calls`): unknown and why where it may call
/// another, one of a choice or any.
fn calledFunction(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!union(enum) { function: Facts.Decl, unknown: Facts.Unknown } {
    const call = (try Facts.calls.at(c.facts, file, node)) orelse return .{ .unknown = .unsupported };
    return switch (call.callee) {
        .function => |function| .{ .function = function },
        .choice => .{ .unknown = .unsupported },
        .any => |why| .{ .unknown = why },
    };
}

/// Whether a type expression is plain data, by the type it resolves to (`plainTyped`).
fn plainType(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: usize) Context.Error!bool {
    if (depth == 64) return false;
    return plainTyped(c, try c.facts.resolve(file, node), &.{});
}

/// Whether a type, or a value of it, is plain data: a primitive type (`usize`, `bool`, `type`),
/// an array or a vector, a pointer or slice, an optional or an error union of plain data, an enum
/// or a struct (a tuple included) every field of which is plain, of no role aegis declares. No
/// aegis owner or capability is such a value. A type not known, or one of a choice that is not
/// plain, is not; a struct already being read (`reading`, a field that holds its own type through
/// a pointer) is not either.
fn plainTyped(c: *Context, value: Facts.Value, reading: []const Facts.Container) Context.Error!bool {
    if (reading.len == 16) return false;
    var each: Facts.Join = .{};
    for (Facts.valueParts(&value)) |part| each.add(part, switch (part) {
        .primitive => true,
        .pointer => |pointer| try plainTyped(c, pointer.child.*, reading),
        .array, .optional, .error_union => |inner| try plainTyped(c, inner.*, reading),
        .container, .instance => |container| blk: {
            if (try c.role(Contract.library, part) != null) break :blk false;
            for (reading) |held| if (held.file == container.file and held.scope == container.scope) break :blk false;
            switch (c.facts.kindOf(container) orelse break :blk false) {
                .keyword_enum => break :blk true,
                .keyword_struct => {},
                else => break :blk false,
            }
            const deeper = try std.mem.concat(c.allocator, Facts.Container, &.{ reading, &.{container} });
            for (try c.facts.heldFields(container)) |field| if (!try plainTyped(c, field.value, deeper)) break :blk false;
            break :blk true;
        },
        .alternatives => unreachable, // unreachable: valueParts gives no choice as a part
        else => false,
    });
    return each.all() == true;
}

/// Whether a value is plain data by what is written where it comes from: a literal, a local or
/// parameter declared plain or initialized with plain data, an element or the address of plain data,
/// or the result of a function declared to return plain data.
fn plainValue(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: usize) Context.Error!bool {
    if (depth == 64) return false;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    // An enum's tag, an error, or a declaration literal naming a container's `const`
    // (`.empty`), known as the program compiles: no live owner (Facts.literalOf).
    if (try c.facts.literalOf(file, node)) |literal| switch (literal) {
        .enum_literal, .error_value, .number, .string, .char => return true,
        else => {},
    };
    // By the expression's form (Facts.accesses.formOf: every tag has one).
    switch (Facts.accesses.formOf(tree.nodeTag(node))) {
        // Zig has no operator overloading: an operator gives a number, a truth value, a vector or
        // (`+`, `-` on a pointer) a pointer, never a struct an owner is.
        .operator, .logic, .comparison => return true,
        .@"comptime", .tried, .address_of => return plainValue(c, file, tree.nodeData(node).node, depth + 1),
        .grouped => return plainValue(c, file, Facts.ungrouped(tree, node), depth + 1),
        // Arrays joined: plain when what they are made of is.
        .concatenation => {
            const sides = tree.nodeData(node).node_and_node;
            return try plainValue(c, file, sides[0], depth + 1) and try plainValue(c, file, sides[1], depth + 1);
        },
        .array_access => return plainValue(c, file, tree.nodeData(node).node_and_node[0], depth + 1),
        // The payload of plain data is plain: Zig requires the other side to coerce to it.
        .@"orelse", .@"catch" => return plainValue(c, file, tree.nodeData(node).node_and_node[0], depth + 1),
        .@"if" => {
            // Peer types: a struct has none with a number, a truth value or a pointer, so one
            // plain branch makes the whole plain (a branch that never ends gives nothing).
            const branch = tree.fullIf(node).?;
            const otherwise = branch.ast.else_expr.unwrap() orelse return false;
            return try plainValue(c, file, branch.ast.then_expr, depth + 1) or try plainValue(c, file, otherwise, depth + 1);
        },
        .body => {
            // `{}`: void.
            var buffer: [2]Ast.Node.Index = undefined;
            const brace = tree.nodeMainToken(node);
            if ((tree.blockStatements(&buffer, node) orelse return false).len == 0 and (brace < 2 or tree.tokenTag(brace - 1) != .colon)) return true;
            return plainBreaks(c, file, node, depth + 1);
        },
        // A literal of plain values, with no type of its own or of a plain type.
        .array_literal => {
            var buffer: [2]Ast.Node.Index = undefined;
            const literal = tree.fullArrayInit(&buffer, node).?; // unreachable: the tag is an array literal's
            if (literal.ast.type_expr.unwrap()) |t| return plainType(c, file, t, depth + 1);
            for (literal.ast.elements) |element| if (!try plainValue(c, file, element, depth + 1)) return false;
            return true;
        },
        .struct_literal => {
            var buffer: [2]Ast.Node.Index = undefined;
            const literal = tree.fullStructInit(&buffer, node).?; // unreachable: the form is a struct literal's
            // One of a type it names is that type's, read where it is.
            if (literal.ast.type_expr != .none) return false;
            for (literal.ast.fields) |field| if (!try plainValue(c, file, field, depth + 1)) return false;
            return true;
        },
        .leaf => {
            const ref = model.reference(node) orelse return false;
            const index = ref.declaration orelse return false;
            const decl = model.declarations[@backingInt(index)];
            if (decl.kind == .parameter) return plainType(c, file, decl.node, depth + 1);
            // A `for` capture over plain inputs: an element of plain data, or a number.
            if (decl.kind == .capture) {
                const loop = tree.fullFor(decl.node) orelse return false;
                for (loop.ast.inputs) |input| {
                    if (Facts.accesses.formOf(tree.nodeTag(input)) == .for_range) continue;
                    if (!try plainValue(c, file, input, depth + 1)) return false;
                }
                return true;
            }
            const v = tree.fullVarDecl(decl.node) orelse return false;
            if (v.ast.type_node.unwrap()) |t| return plainType(c, file, t, depth + 1);
            const init = v.ast.init_node.unwrap() orelse return false;
            return plainValue(c, file, init, depth + 1);
        },
        .call => {
            // A call that may be of another function is not known plain here: its value's type
            // decides it where this is read.
            const origin = switch (try calledFunction(c, file, node)) {
                .function => |function| function,
                .unknown => return false,
            };
            const record = c.project.at(origin.file).model.declarations[@backingInt(origin.index)];
            const written = &c.project.at(origin.file).file.tree;
            var proto_buffer: [1]Ast.Node.Index = undefined;
            const proto = written.fullFnProto(&proto_buffer, record.node) orelse return false;
            const result = proto.ast.return_type.unwrap() orelse return false;
            return plainType(c, origin.file, result, depth + 1);
        },
        else => return false,
    }
}

/// Whether every `break` out of the labeled block `node` gives plain data; false for a block
/// with no label, which gives no value.
fn plainBreaks(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: usize) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const lbrace = tree.nodeMainToken(node);
    if (lbrace < 2 or tree.tokenTag(lbrace - 1) != .colon or tree.tokenTag(lbrace - 2) != .identifier) return false;
    const label = tree.tokenSlice(lbrace - 2);
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var found = false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break") continue;
        const brk: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(brk);
        if (at < first or at > last) continue;
        const data = tree.nodeData(brk).opt_token_and_opt_node;
        const target = data[0].unwrap() orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(target), label)) continue;
        const value = data[1].unwrap() orelse return false;
        if (!try plainValue(c, file, value, depth)) return false;
        found = true;
    }
    return found;
}

/// The local a write to `place` lands in: its root's, or, through a pointer capture over a
/// local's bytes (`for (std.mem.asBytes(&v)) |*d| d.* = s`), that local's.
fn writtenLocal(c: *Context, place: Ast.Node.Index) Context.Error!?Model.Declaration.Id {
    const root = (try placeRoot(c, place)) orelse return null;
    const local = Contract.local(c, root) orelse return null;
    const decl = c.project.at(c.file).model.declarations[@backingInt(local)];
    if (decl.kind != .capture) return local;
    const source = c.facts.captureSource(c.file, decl) orelse return local;
    const bytes = (try addressed(c, source)) orelse return local;
    const inner = (try placeRoot(c, bytes)) orelse return local;
    return Contract.local(c, inner) orelse local;
}

/// The place `std.mem.asBytes(&x)` names: `x`.
/// What `std.mem.asBytes(&x)` gives the bytes of: `x`, its callee read by resolution.
fn addressed(c: *Context, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const tree = try c.project.syntax(try c.source());
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (call.ast.params.len != 1) return null;
    const function = switch (try calledFunction(c, c.file, node)) {
        .function => |function| function,
        .unknown => return null,
    };
    if (try isStd(c, function, "mem.asBytes") != .yes) return null;
    const operand = call.ast.params[0];
    if (Facts.accesses.formOf(tree.nodeTag(operand)) != .address_of) return null;
    return tree.nodeData(operand).node;
}

/// Whether `name` is one of a catalogue's `names`.
fn among(names: []const []const u8, name: []const u8) bool {
    for (names) |each| if (std.mem.eql(u8, each, name)) return true;
    return false;
}

/// Whether `node` names the type `type`, by what it resolves to.
fn typeKeyword(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?bool {
    const value = try c.facts.resolve(file, node);
    var each: Facts.Join = .{};
    for (Facts.valueParts(&value)) |part| each.add(part, switch (part) {
        .primitive => |primitive| std.mem.eql(u8, primitive, "type"),
        .alternatives => unreachable, // unreachable: valueParts gives no choice as a part
        else => false,
    });
    return each.agreed();
}

/// The names among the tokens `first` to `last` that reach the declaration at `token`, by the
/// model's resolution of each (an enum literal spelled alike reaches none).
const Mentions = struct {
    model: *const Model,
    token: Ast.TokenIndex,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    at: usize = 0,

    fn of(model: *const Model, token: Ast.TokenIndex, tree: *const Ast, node: Ast.Node.Index) Mentions {
        return .{ .model = model, .token = token, .first = tree.firstToken(node), .last = tree.lastToken(node) };
    }

    /// Every name in the file that reaches the declaration at `token`.
    fn all(model: *const Model, token: Ast.TokenIndex) Mentions {
        return .{ .model = model, .token = token, .first = 0, .last = std.math.maxInt(Ast.TokenIndex) };
    }

    fn next(m: *Mentions) ?Ast.Node.Index {
        while (m.at < m.model.references.len) {
            const ref = m.model.references[m.at];
            m.at += 1;
            if (ref.unknown != null or ref.token < m.first or ref.token > m.last) continue;
            const index = ref.declaration orelse continue;
            if (m.model.declarations[@backingInt(index)].token == m.token) return ref.node;
        }
        return null;
    }
};

/// Whether a call gives a scalar's raw integer: it calls the scalar's `raw`, by any name it
/// is reached through, on a scalar (`s.raw()`, `Index.raw(s)`, a constant naming it).
fn raw(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    // Of a value a generic parameter gives: each binding's, checked there.
    if (try c.facts.rawAtBinding(c.file, node)) return false;
    return rawCall(c, call.ast.fn_expr, call.ast.params, tree.nodeMainToken(node));
}

/// Whether calling `callee` with `params` gives a scalar's raw integer: a method call on a
/// scalar, or the function given the scalar first. A callee that does not resolve, on a
/// scalar or given one, is undecided at the callee unless it is spelled `raw`.
fn rawCall(c: *Context, callee: Ast.Node.Index, params: []const Ast.Node.Index, token: Ast.TokenIndex) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    const method = tree.nodeTag(callee) == .field_access and params.len == 0;
    const named: Is = switch (try c.facts.definition(c.file, callee)) {
        .decl => |decl| switch (try c.facts.origin(decl)) {
            .decl => |target| if (std.mem.eql(u8, c.project.at(target.file).model.declarations[@backingInt(target.index)].name, "raw")) .yes else .no,
            .none => .no,
            .unknown => |why| .{ .unknown = why },
        },
        // A name of no declaration (`u8`) calls none; any other callee (`f()(s)`) is not read.
        .none => switch (tree.nodeTag(callee)) {
            .identifier, .field_access => .no,
            else => .{ .unknown = .unsupported },
        },
        .unknown => |why| .{ .unknown = why },
    };
    // Unresolved: the call's own spelling.
    const spelled = tree.nodeTag(callee) == .field_access and std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(callee).node_and_token[1])), "raw");
    // Spelled `raw` but known another: only a method on a scalar is read by its spelling.
    if (named == .no and !(spelled and method)) return false;
    const given = if (method) tree.nodeData(callee).node_and_token[0] else if (params.len == 1) params[0] else return false;
    if (try requiredOwner(c, given, scalar, token) != .scalar) return false;
    switch (named) {
        .yes => return true,
        .no => return true,
        .unknown => |why| {
            if (method and spelled) return true;
            try c.unknown(scalar, callee, why);
            return false;
        },
    }
}
/// std's reinterpreting reads, by meaning: the bytes of what they are given (`asBytes`,
/// `toBytes`, `sliceAsBytes`) and a value read out of bytes (`readInt`, `readVarInt`,
/// `bytesToValue`, `bytesAsValue`, `bytesAsSlice`), with the position of the argument read.
const reinterpreting = [_]struct { []const u8, usize }{
    .{ "mem.asBytes", 0 },    .{ "mem.toBytes", 0 },      .{ "mem.sliceAsBytes", 0 }, .{ "mem.readInt", 1 },
    .{ "mem.readVarInt", 1 }, .{ "mem.bytesToValue", 1 }, .{ "mem.bytesAsValue", 1 }, .{ "mem.bytesAsSlice", 1 },
};

/// Whether a call of one of std's reinterpreting reads gives a scalar's integer: its bytes
/// (`std.mem.asBytes(&i)`), or what is read out of them (`std.mem.readInt(u16, bytes, .little)`).
fn rawBytes(c: *Context, node: Ast.Node.Index, seen: []const Model.Declaration.Id) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    for (reinterpreting) |each| {
        const path, const position = each;
        if (position >= call.ast.params.len) continue;
        const given = call.ast.params[position];
        switch (try stdCall(c, node, path)) {
            .no => continue,
            .yes => return try rawValue(c, given, seen) or try requiredOwner(c, given, scalar, tree.nodeMainToken(node)) == .scalar,
            // A call that may be the read, given a scalar's integer: undecided at the call.
            .unknown => |why| {
                if (try rawValue(c, given, seen) or try requiredOwner(c, given, scalar, tree.nodeMainToken(node)) == .scalar) try c.unknown(scalar, node, why);
                return false;
            },
        }
    }
    return false;
}

/// Whether `node` may give what a scalar's `raw()` returned: the call itself, or that value
/// carried unchanged through a grouping, `try`, `comptime`, `@as`, a branch of an `if`, an
/// `orelse`, a `catch`, a `switch` or a labeled block's `break`, or a local: a constant it
/// initializes, a variable it initializes or is assigned (`=` or a compound assignment) anywhere.
/// What an operator makes of it is reported at the operator, not carried further. `seen` holds
/// the locals the value is already being followed through.
fn rawValue(c: *Context, node: Ast.Node.Index, seen: []const Model.Declaration.Id) Context.Error!bool {
    // What the value may be, through the forms that carry or choose it (Facts.accesses.valuesOf):
    // each one read whole.
    const leaves = switch (try Facts.accesses.valuesOf(c.facts, c.file, node)) {
        .leaves => |leaves| leaves,
        .unknown => return false,
    };
    for (leaves) |leaf| if (try rawLeaf(c, leaf, seen)) return true;
    return false;
}
/// Whether a value of a form that neither carries nor chooses another is what a scalar's `raw()`
/// returned, or holds it.
fn rawLeaf(c: *Context, node: Ast.Node.Index, seen: []const Model.Declaration.Id) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    switch (Facts.accesses.formOf(tree.nodeTag(node))) {
        .call => return try raw(c, node) or try rawBytes(c, node, seen),
        .builtin => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            // The value in each lane (`@as` gives it unchanged: valuesOf reads through it).
            if (std.mem.eql(u8, name, "@splat")) return args.len == 1 and try rawValue(c, args[0], seen);
            // A scalar's integer read out by the language.
            if (std.mem.eql(u8, name, "@backingInt") or std.mem.eql(u8, name, "@intFromEnum")) {
                // Of a value a generic parameter gives: each binding's.
                if (try c.facts.castAtBinding(c.file, node)) return false;
                return args.len == 1 and try requiredOwner(c, args[0], scalar, tree.nodeMainToken(node)) == .scalar;
            }
            // A scalar's bits read as another type, or a pointer to them (`@bitCast(i)`,
            // `@as(*const u16, @ptrCast(&i)).*`): its integer, reinterpreted. A raw value's
            // `@bitCast` is a cast, reported there; a pointer to one still points at it.
            if (std.mem.eql(u8, name, "@bitCast") or std.mem.eql(u8, name, "@ptrCast")) {
                if (args.len != 1 or try c.facts.castAtBinding(c.file, node)) return false;
                if (std.mem.eql(u8, name, "@ptrCast") and try rawValue(c, args[0], seen)) return true;
                return try requiredOwner(c, args[0], scalar, tree.nodeMainToken(node)) == .scalar;
            }
            // `@call(modifier, Index.raw, .{s})`.
            if (std.mem.eql(u8, name, "@call") and args.len == 3) {
                if (try c.facts.castAtBinding(c.file, node)) return false;
                var tuple_buffer: [2]Ast.Node.Index = undefined;
                const tuple = tree.fullArrayInit(&tuple_buffer, args[2]) orelse return false;
                return rawCall(c, args[1], tuple.ast.elements, tree.nodeMainToken(node));
            }
            return false;
        },
        // A part of what holds it, or a pointer to it: a field, an element, a payload, what a
        // pointer points at (`.len` of an array is its own length).
        .member => {
            const data = tree.nodeData(node).node_and_token;
            // A slice's or array's own length (or address) is none of a scalar's raw value.
            if (try c.facts.memoryField(c.file, node) != .field) return false;
            return rawValue(c, data[0], seen);
        },
        .deref, .address_of => return rawValue(c, tree.nodeData(node).node, seen),
        .array_access => return rawValue(c, tree.nodeData(node).node_and_node[0], seen),
        // A name: a local's or a capture's value; a literal holds none.
        .leaf => {
            const index = Contract.local(c, node) orelse return false;
            for (seen) |s| if (s == index) return false;
            const model = &c.project.at(c.file).model;
            const decl = model.declarations[@backingInt(index)];
            const followed = try std.mem.concat(c.allocator, Model.Declaration.Id, &.{ seen, &.{index} });
            // A capture: of what the `if`, loop or `switch` reads.
            if (decl.kind == .capture) return if (c.facts.captureSource(c.file, decl)) |source| rawValue(c, source, followed) else false;
            if (decl.kind != .variable) return false;
            const v = tree.fullVarDecl(decl.node) orelse return false;
            if (v.ast.init_node.unwrap()) |init| {
                if (try rawValue(c, init, followed)) return true;
            } else if (model.parentOf(decl.node)) |parent| if (Facts.accesses.formOf(tree.nodeTag(parent)) == .destructure) {
                // `const a, const b = .{ s.raw(), 0 };`: what is destructured.
                if (try rawValue(c, tree.assignDestructure(parent).ast.value_expr, followed)) return true;
            };
            if (tree.tokenTag(v.ast.mut_token) != .keyword_var) return false;
            // Anything put in it, whole or in a part, by any assignment, a destructure, or a
            // copy of bytes into it (`@memcpy(std.mem.asBytes(&v), std.mem.asBytes(&i))`).
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (Facts.accesses.formOf(tag) == .destructure) {
                    const destructure = tree.assignDestructure(at);
                    for (destructure.ast.variables) |target| {
                        if (try writtenLocal(c, target) == index and try rawValue(c, destructure.ast.value_expr, followed)) return true;
                    }
                    continue;
                }
                if (try Facts.accesses.copyAt(c.facts, c.file, at)) |copy| {
                    if (try writtenLocal(c, copy.into.node()) != index) continue;
                    if (try rawValue(c, copy.from.node(), followed) or try requiredOwner(c, copy.from.node(), scalar, tree.nodeMainToken(at)) == .scalar) return true;
                    continue;
                }
                if (!assigning(tag)) continue;
                const sides = tree.nodeData(at).node_and_node;
                if (try writtenLocal(c, sides[0]) != index) continue;
                if (try rawValue(c, sides[1], followed)) return true;
            }
            return false;
        },
        // A literal holding it in a field or an element.
        .struct_literal => {
            var buffer: [2]Ast.Node.Index = undefined;
            for (tree.fullStructInit(&buffer, node).?.ast.fields) |field| if (try rawValue(c, field, seen)) return true; // unreachable: the form is a struct literal's
            return false;
        },
        .array_literal => {
            var buffer: [2]Ast.Node.Index = undefined;
            for (tree.fullArrayInit(&buffer, node).?.ast.elements) |element| if (try rawValue(c, element, seen)) return true; // unreachable: the form is an array literal's
            return false;
        },
        else => return false,
    }
}

/// An assignment, plain or compound: each writes its left side from its right.
fn assigning(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .assign, .assign_add, .assign_add_wrap, .assign_add_sat, .assign_sub, .assign_sub_wrap, .assign_sub_sat, .assign_mul, .assign_mul_wrap, .assign_mul_sat, .assign_div, .assign_mod, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor => true,
        else => false,
    };
}

/// The builtins that convert or reinterpret an integer: each can discard what a scalar checks.
const scalar_casts = [_][]const u8{ "@intCast", "@truncate", "@enumFromInt", "@bitCast", "@floatFromInt", "@ptrFromInt", "@byteSwap", "@bitReverse" };
/// The builtins that compute with integers, outside the scalar's own checked operations.
const scalar_arithmetic = [_][]const u8{ "@divTrunc", "@divFloor", "@divExact", "@mod", "@rem", "@shlExact", "@shrExact", "@addWithOverflow", "@subWithOverflow", "@mulWithOverflow", "@shlWithOverflow", "@min", "@max", "@abs" };

/// A type's values: a container type stands for its instances.
fn instanceOf(c: *Context, value: Facts.Value) Context.Error!Facts.Value {
    return switch (value) {
        .container => |container| .{ .instance = container },
        // A choice of types stands for a choice of their values.
        .alternatives => |each| blk: {
            const parts = try c.allocator.alloc(Facts.Value, each.len);
            for (each, parts) |one, *part| part.* = switch (one) {
                .container => |container| .{ .instance = container },
                .alternatives => unreachable, // unreachable: choose never nests alternatives
                else => one,
            };
            break :blk .{ .alternatives = parts };
        },
        else => value,
    };
}

fn listed(name: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

fn checkScalar(c: *Context) Context.Error!void {
    if (!try begin(c, scalar)) return;
    const tree = try c.project.syntax(try c.source());
    const operation = "raw aegis scalar operation bypasses domain/unit or checked arithmetic; explicit boundary semantics required";
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        try checkBinding(c, tree, node, scalar);
        switch (tag) {
            .add, .add_wrap, .add_sat, .sub, .sub_wrap, .sub_sat, .mul, .mul_wrap, .mul_sat, .div, .mod, .shl, .shl_sat, .shr, .bit_and, .bit_or, .bit_xor, .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal => {
                const operands = tree.nodeData(node).node_and_node;
                if (try rawValue(c, operands[0], &.{}) or try rawValue(c, operands[1], &.{})) try c.at(scalar, tree.nodeMainToken(node), operation);
            },
            .negation, .negation_wrap, .bit_not => if (try rawValue(c, tree.nodeData(node).node, &.{})) try c.at(scalar, tree.nodeMainToken(node), operation),
            else => {},
        }
        // A compound assignment is the operator's: `n += s.raw()` computes as `n + s.raw()`.
        if (Facts.accesses.formOf(tag) == .compound_assign) {
            const operands = tree.nodeData(node).node_and_node;
            if (try rawValue(c, operands[0], &.{}) or try rawValue(c, operands[1], &.{})) try c.at(scalar, tree.nodeMainToken(node), operation);
        }
        // std's reads of a value out of bytes or an integer into a scalar's type
        // (`bytesToValue(Index, &b)`, `std.enums.fromInt(Index, v)`) skip its checked
        // construction as the language's casts do.
        if (try Facts.calls.at(c.facts, c.file, node)) |call| {
            // Why the call may be one of them, where it is not known to be.
            var maybe: ?Facts.Unknown = null;
            const made = for ([_][]const u8{ "mem.bytesToValue", "mem.bytesAsValue", "mem.bytesAsSlice", "enums.fromInt" }) |path| switch (try stdCall(c, node, path)) {
                .yes => break true,
                .no => {},
                .unknown => |why| maybe = why,
            } else false;
            if (!made and maybe == null) continue;
            const args = switch (call.args) {
                .known => |args| args,
                .unknown => |why| {
                    try c.unknown(scalar, node, why);
                    continue;
                },
            };
            if (args.len == 0) continue;
            switch (try perBuild(c, try instanceOf(c, try c.facts.resolve(c.file, args[0])))) {
                .owner => |k| if (k == .scalar) {
                    if (made) {
                        try c.at(scalar, tree.nodeMainToken(node), "an aegis scalar made out of bytes or an integer by std skips its checked construction; use the scalar's checked constructor or justify the boundary");
                    } else if (maybe) |why| try c.unknown(scalar, node, why);
                },
                .other => {},
                .unknown => try c.undecided(scalar, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "the type std makes here does not resolve: it may be an aegis scalar made without its checked construction"),
            }
            continue;
        }
        if (Facts.builtinName(tree, node)) |name| {
            // An integer made into a scalar by the language, or bits reinterpreted as one
            // (`@bitCast(v)`, `@ptrCast` to a pointer to one), skips its checked construction.
            if (std.mem.eql(u8, name, "@enumFromInt") or std.mem.eql(u8, name, "@fromBackingInt") or std.mem.eql(u8, name, "@bitCast") or std.mem.eql(u8, name, "@ptrCast")) {
                // By a generic parameter's type: each binding's, checked there.
                if (try c.facts.castAtBinding(c.file, node)) continue;
                switch (try perBuild(c, try instanceOf(c, try c.facts.literalType(c.file, node)))) {
                    .owner => |k| if (k == .scalar) {
                        try c.at(scalar, tree.nodeMainToken(node), "an integer made into an aegis scalar by a cast skips its checked construction; use the scalar's checked constructor or justify the boundary");
                        continue;
                    },
                    .other => {},
                    .unknown => try c.undecided(scalar, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "the type this cast makes does not resolve: it may be an aegis scalar made without its checked construction"),
                }
            }
            const cast = listed(name, &scalar_casts);
            if (!cast and !listed(name, &scalar_arithmetic)) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            for (Facts.builtinArgs(tree, node, &buffer)) |arg| if (try rawValue(c, arg, &.{})) {
                try c.at(scalar, tree.nodeMainToken(node), if (cast) "raw aegis scalar cast can discard domain/range/all-build failure checks; use checked conversion or justify boundary" else operation);
                break;
            };
        }
    }
}
