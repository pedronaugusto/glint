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
const Undefined = @import("Undefined.zig");
const Flows = @import("DangerFlow.zig");
const Program = @import("Program.zig");
const Rule = @import("Rule.zig").Rule;
const Report = @import("Report.zig");
const Ast = std.zig.Ast;
pub const access = Ids.access;
pub const copies = Ids.copies;
pub const cleanup = Ids.cleanup;
pub const scalar = Ids.scalar;
pub const capacity = Ids.capacity;
pub const recursion = Ids.recursion;
// The danger rules (designs/aegis.md §7): each finds where its danger exists and aegis's type is
// the answer, from what the code resolves to.
pub const shared_state = Ids.shared_state;
pub const secrets = Ids.secrets;
pub const untrusted_input = Ids.untrusted_input;
pub const integers = Ids.integers;
pub const units = Ids.units;
pub const bounded_work = Ids.bounded_work;
pub const contracts = Ids.contracts;
pub const lifetimes = Ids.lifetimes;
pub const ownership = Ids.ownership;
pub const identity = Ids.identity;
pub const state_machines = Ids.state_machines;
pub const diagnostics = Ids.diagnostics;
pub const unsafe_set = Ids.unsafe_set;
pub const cancellation = Ids.cancellation;
pub const lock_order = Ids.lock_order;
/// Aegis's package, as its `build.zig.zon` names it: a caller states it for aegis's files.
pub const package = Contract.package;
/// The danger rules: each finds where a danger exists and aegis's type is the answer.
pub const danger = [_]Rule{ shared_state, secrets, untrusted_input, integers, units, bounded_work, contracts, lifetimes, ownership, identity, state_machines, diagnostics, unsafe_set, cancellation, lock_order };
/// The first file outside aegis whose import resolves to an aegis module (`Facts.moduleRoots`):
/// one, whatever the program names it after and whatever its package, that publishes what the
/// module does; or one of aegis's name that publishes some of it, does not resolve far enough
/// to tell, or does not parse, whose missing members the run then reports. A module of aegis's
/// name that publishes none of it is not aegis.
pub fn importer(gpa: std.mem.Allocator, project: *const Project) Facts.ResolveError!?Project.FileId {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var facts: Facts = .{ .project = project, .gpa = arena.allocator(), .known = Contract.package };
    for (project.imports) |mapping| {
        if (facts.knownFile(mapping.from)) continue;
        for (Contract.library.modules) |module| {
            if (std.mem.findScalar(Project.FileId, try facts.moduleRoots(module), mapping.target) == null) continue;
            if (project.at(mapping.target).file.status != .parsed or try facts.publishesAny(module, mapping.target) != .no) return mapping.from;
        }
    }
    return null;
}

pub const rules = [_]Context.Rule{
    .{ .definition = .{ .id = access, .name = "A001", .group = .family_policy, .purpose = "secret disclosure or shared-state access without a live capability", .version = 2, .exception = .aegis }, .check = checkAccess },
    .{ .definition = .{ .id = copies, .name = "A002", .group = .family_policy, .purpose = "duplicated secret owner or lock capability; borrowed storage escapes", .version = 2, .exception = .aegis }, .check = checkCopies },
    .{ .definition = .{ .id = cleanup, .name = "A003", .group = .family_policy, .purpose = "missing owner cleanup or use after cleanup/transfer on a supported local path", .version = 2, .exception = .aegis }, .check = checkCleanup },
    .{ .definition = .{ .id = scalar, .name = "A004", .group = .family_policy, .purpose = "domain/unit or all-build integer checks bypassed by raw arithmetic/casts", .version = 2, .exception = .aegis }, .check = checkScalar },
    .{ .definition = .{ .id = capacity, .name = "A005", .group = .family_policy, .purpose = "SecretBytes adoption truncates wipe capacity or lacks proven allocation ownership", .version = 2, .exception = .aegis }, .check = checkCapacity },
    .{ .definition = .{ .id = recursion, .name = "A006", .group = .family_policy, .purpose = "recursion reachable from untrusted input without a depth bound", .version = 1, .exception = .aegis }, .check = checkRecursion, .facts = &.{Danger.peer_input} },
    .{ .definition = .{ .id = shared_state, .name = "A007", .group = .family_policy, .purpose = "shared state outside aegis's guards", .exception = .aegis }, .check = checkSharedState },
    .{ .definition = .{ .id = secrets, .name = "A008", .group = .family_policy, .purpose = "secret material outside aegis's Secret and Choice", .exception = .aegis }, .check = checkSecrets },
    .{ .definition = .{ .id = untrusted_input, .name = "A009", .group = .family_policy, .purpose = "input used before a parser refines it", .exception = .aegis }, .check = checkInput, .facts = &.{Danger.peer_input} },
    .{ .definition = .{ .id = integers, .name = "A010", .group = .family_policy, .purpose = "integer conversion or arithmetic on input that a peer can make fail", .exception = .aegis }, .check = checkIntegers, .facts = &.{Danger.peer_input} },
    .{ .definition = .{ .id = units, .name = "A011", .group = .family_policy, .purpose = "time crossing to std as a raw integer", .exception = .aegis }, .check = checkUnits },
    .{ .definition = .{ .id = bounded_work, .name = "A012", .group = .family_policy, .purpose = "work sized by input without a stated limit", .exception = .aegis }, .check = checkBoundedWork, .facts = &.{Danger.bounded_input} },
    .{ .definition = .{ .id = contracts, .name = "A013", .group = .family_policy, .purpose = "contract that is undefined behaviour when false in a release build", .exception = .aegis }, .check = checkContracts, .facts = &.{Danger.peer_input} },
    .{ .definition = .{ .id = lifetimes, .name = "A014", .group = .family_policy, .purpose = "pointer that outlives what it points into", .exception = .aegis }, .check = checkLifetimes },
    .{ .definition = .{ .id = ownership, .name = "A015", .group = .family_policy, .purpose = "std resource held or returned without its one owner", .exception = .aegis }, .check = checkOwnership },
    .{ .definition = .{ .id = identity, .name = "A016", .group = .family_policy, .purpose = "identifying integers of one type that one may pass for another", .exception = .aegis }, .check = checkIdentity },
    .{ .definition = .{ .id = state_machines, .name = "A017", .group = .family_policy, .purpose = "state machine kept by hand", .exception = .aegis }, .check = checkStateMachines },
    .{ .definition = .{ .id = diagnostics, .name = "A018", .group = .family_policy, .purpose = "internal text written to a peer", .exception = .aegis }, .check = checkDiagnostics, .facts = &.{ Danger.peer_writer, Danger.error_text } },
    .{ .definition = .{ .id = unsafe_set, .name = "A019", .group = .family_policy, .purpose = "operation Zig leaves unchecked", .exception = .aegis }, .check = checkUnsafeSet },
    .{ .definition = .{ .id = cancellation, .name = "A020", .group = .family_policy, .purpose = "loop on input or without bound that cannot be canceled", .exception = .aegis }, .check = checkCancellation, .facts = &.{Danger.peer_input} },
    .{ .definition = .{ .id = lock_order, .name = "A021", .group = .family_policy, .purpose = "two aegis guards held at once without both ranked by Order", .exception = .aegis }, .check = checkLockOrder },
};
fn checkInput(c: *Context) Context.Error!void {
    if (try begin(c, untrusted_input)) try Flows.input(c, untrusted_input);
}
fn checkBoundedWork(c: *Context) Context.Error!void {
    if (try begin(c, bounded_work)) try Flows.boundedWork(c, bounded_work);
}
fn checkDiagnostics(c: *Context) Context.Error!void {
    if (try begin(c, diagnostics)) try Flows.diagnostics(c, diagnostics);
}
fn checkCancellation(c: *Context) Context.Error!void {
    if (try begin(c, cancellation)) try Flows.cancellation(c, cancellation);
}
fn checkSharedState(c: *Context) Context.Error!void {
    if (try begin(c, shared_state)) try Danger.sharedState(c, shared_state);
}
fn checkSecrets(c: *Context) Context.Error!void {
    if (try begin(c, secrets)) try Danger.secrets(c, secrets);
}
fn checkIntegers(c: *Context) Context.Error!void {
    if (!try begin(c, integers)) return;
    try Flows.integers(c, integers);
}
fn checkUnits(c: *Context) Context.Error!void {
    if (try begin(c, units)) try Danger.units(c, units);
}
fn checkContracts(c: *Context) Context.Error!void {
    if (try begin(c, contracts)) try Danger.contracts(c, contracts);
}
fn checkLifetimes(c: *Context) Context.Error!void {
    if (!try begin(c, lifetimes)) return;
    try Danger.lifetimes(c, lifetimes);
    try Shapes.borrowsStored(c, lifetimes);
}
fn checkLockOrder(c: *Context) Context.Error!void {
    if (try begin(c, lock_order)) try Shapes.lockOrder(c, lock_order);
}
fn checkOwnership(c: *Context) Context.Error!void {
    if (try begin(c, ownership)) try Shapes.ownership(c, ownership);
}
fn checkIdentity(c: *Context) Context.Error!void {
    if (try begin(c, identity)) try Shapes.identity(c, identity);
}
fn checkStateMachines(c: *Context) Context.Error!void {
    if (try begin(c, state_machines)) try Shapes.stateMachines(c, state_machines);
}
fn checkUnsafeSet(c: *Context) Context.Error!void {
    if (!try begin(c, unsafe_set)) return;
    try Danger.unsafeSet(c, unsafe_set);
    try Undefined.reads(c, unsafe_set, followsCleanup);
}
fn checkRecursion(c: *Context) Context.Error!void {
    if (!try begin(c, recursion)) return;
    try @import("AegisRecursion.zig").check(c, recursion);
}
/// Starts a check of this file. The library's own files are its safe-type internals, and a
/// published member that no longer resolves is reported where the library is imported, so a
/// renamed declaration cannot make a gate quietly stop seeing it.
fn begin(c: *Context, rule: Rule) Context.Error!bool {
    if (try c.inLibrary(Contract.library, c.file)) return false;
    if (try c.drift(Contract.library)) |gap| {
        const detail = try c.allocator.print("published member {s} of {s} does not resolve ({t}); its operations are not recognized in this file", .{ gap.path, gap.module, gap.why });
        try c.undecided(rule, gap.start, .unresolved, detail);
    }
    return true;
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
        if (made_by_constructor.len != 0) {
            try checkLiteral(c, tree, node, made_by_constructor);
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
        if (!backingName(name)) continue;
        const holder = path.steps[1].node;
        const token = tree.lastToken(node);
        if (try typeValue(c, holder)) continue;
        if (try refuted(c, node, name)) continue;
        const k = (try requiredOwner(c, holder, access, token)) orelse continue;
        if (backing(k, name)) try c.at(access, token, "published aegis backing field bypasses exposure/guard/ownership contract; review this access");
    }
}

/// A backing field named by `@field`, as a member access names it: by a name it spells
/// (`@field(g, "data")`, `"\x64ata"`, a `const` that holds it), by each field of a struct
/// whose `field_names` it ranges over that is one; by a name it computes, any field of the
/// holder, undecided where the holder's kind has a backing field.
fn checkFieldBuiltin(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!void {
    if (!Facts.isBuiltin(tree, node, "@field")) return;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 2) return;
    const holder = args[0];
    const token = tree.nodeMainToken(node);
    const named = try c.facts.fieldName(c.file, args[1]);
    switch (named) {
        .name => |name| if (!backingName(name)) return,
        .each_of, .names => {
            if (!backingNamed(c, named, null)) return;
        },
        .computed => {},
    }
    if (try typeValue(c, holder)) return;
    const k = (try requiredOwner(c, holder, access, token)) orelse return;
    if (named == .computed) {
        if (anyBacking(k)) try c.undecided(access, tree.tokenStart(token), .unresolved, "a name @field computes may be a published aegis backing field");
        return;
    }
    if (backingNamed(c, named, k)) try c.at(access, token, "published aegis backing field bypasses exposure/guard/ownership contract; review this access");
}
/// Whether a name `@field` spells or ranges over is a backing field: of kind `k`, or of any.
fn backingNamed(c: *Context, named: Facts.FieldName, k: ?Contract.Kind) bool {
    switch (named) {
        .name => |name| return if (k) |kind| backing(kind, name) else backingName(name),
        .computed => return true,
        .each_of, .names => {
            for (std.enums.values(Contract.Kind)) |each| {
                if (k) |kind| if (each != kind) continue;
                for (backingFields(each)) |name| if (c.facts.mayName(named, name)) return true;
            }
            return false;
        },
    }
}

/// The bytes of a published owner read outside aegis: a std byte view of it
/// (`std.mem.asBytes(s)`, `toBytes`, `sliceAsBytes`) or `@bitCast` of it reads every field
/// it keeps behind its operations at once. A byte view of what does not resolve is undecided
/// where it may be an owner, as is an owner given to a call that may be a byte view.
fn checkByteRead(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!void {
    // Why the call may be a byte view or not, where it is not known to be one.
    var maybe: ?Facts.Unknown = null;
    const operand: Ast.Node.Index = blk: {
        if (Facts.builtinName(tree, node)) |name| {
            if (!std.mem.eql(u8, name, "@bitCast")) return;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 1) return;
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
        .owner => |k| if (anyBacking(k)) {
            if (maybe) |why| return c.unknown(access, node, why);
            try c.at(access, token, "the bytes of a published aegis owner read whole bypass its exposure/guard/ownership contract; use its operations");
        },
        .other, .unknown => {},
    }
}

/// Whether a kind publishes any backing field (`backing`).
fn anyBacking(k: Contract.Kind) bool {
    return backingFields(k).len != 0;
}
/// The published types only their own constructor may make: `err.PublicSource`, whose
/// `classify` takes the reviewed reason that a literal of it skips.
fn constructed(c: *Context) Context.Error![]const Facts.Container {
    const found = try c.facts.publication(Contract.library);
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
    switch (try typed(c, try c.facts.literalType(c.file, node), 0)) {
        .owner => |k| if (k == .public_source) try c.at(access, tree.firstToken(node), "public text built by a literal skips its reviewed classification; use err.PublicSource.classify(reason, bytes)"),
        .other => {},
        .unknown => try c.undecided(access, tree.tokenStart(tree.firstToken(node)), .unresolved, "a literal that may be a public source has no resolved result type"),
    }
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
    if (!writable(c, tree, operand)) return;
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
fn writable(c: *Context, tree: *const Ast, place: Ast.Node.Index) bool {
    const root = placeRoot(tree, place) orelse return true;
    if (root != place) {
        // Through a pointer: what it points at, whatever holds the pointer.
        var at = place;
        while (at != root) : (at = switch (tree.nodeTag(at)) {
            .field_access, .unwrap_optional, .grouped_expression => tree.nodeData(at).node_and_token[0],
            .deref => return true,
            .array_access, .slice_open => tree.nodeData(at).node_and_node[0],
            else => return true,
        }) {}
    }
    const model = &c.project.at(c.file).model;
    const index = (model.reference(root) orelse return true).declaration orelse return true;
    const decl = model.declarations[@backingInt(index)];
    return switch (decl.kind) {
        .variable => tree.tokenTag((tree.fullVarDecl(decl.node) orelse return true).ast.mut_token) == .keyword_var,
        .parameter => false,
        else => true,
    };
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
    const found = try c.facts.publication(Contract.library);
    for (found.files) |file| {
        const model = &c.project.at(file).model;
        for (model.declarations) |decl| {
            if (decl.kind != .field or !std.mem.eql(u8, decl.name, name)) continue;
            const holder: Facts.Container = .{ .file = file, .scope = decl.scope };
            switch (try typed(c, .{ .instance = holder }, 0)) {
                .owner => |k| if (!backing(k, name)) continue,
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
/// and argument-less calls. Zig types each such expression alike, wherever it is written.
fn receiverMembers(c: *Context, tree: *const Ast, model: *const Model, receiver: Ast.Node.Index, name: []const u8) Context.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    if (!alikeRooted(tree, model, receiver, 0)) return names.items;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .field_access) continue;
        const access_node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const data = tree.nodeData(access_node).node_and_token;
        if (data[0] == receiver or !typedAlike(tree, model, data[0], receiver, 0)) continue;
        const read = try Model.identifier(c.allocator, tree.tokenSlice(data[1]));
        if (std.mem.eql(u8, read, name)) continue;
        for (names.items) |earlier| {
            if (std.mem.eql(u8, earlier, read)) break;
        } else try names.append(c.allocator, read);
    }
    return names.items;
}
/// Whether `node` is an expression `typedAlike` compares: rooted at a declaration it names.
fn alikeRooted(tree: *const Ast, model: *const Model, node: Ast.Node.Index, depth: usize) bool {
    if (depth == 16) return false;
    return switch (tree.nodeTag(node)) {
        .identifier => if (model.reference(node)) |ref| ref.declaration != null else false,
        .field_access, .unwrap_optional, .grouped_expression => alikeRooted(tree, model, tree.nodeData(node).node_and_token[0], depth + 1),
        .deref, .@"try" => alikeRooted(tree, model, tree.nodeData(node).node, depth + 1),
        .array_access => alikeRooted(tree, model, tree.nodeData(node).node_and_node[0], depth + 1),
        .call_one, .call_one_comma => tree.nodeData(node).node_and_opt_node[1] == .none and alikeRooted(tree, model, tree.nodeData(node).node_and_opt_node[0], depth + 1),
        else => false,
    };
}
fn typedAlike(tree: *const Ast, model: *const Model, a: Ast.Node.Index, b: Ast.Node.Index, depth: usize) bool {
    if (depth == 16) return false;
    const tag = tree.nodeTag(a);
    if (tag != tree.nodeTag(b)) return false;
    return switch (tag) {
        .identifier => blk: {
            const x = (model.reference(a) orelse break :blk false).declaration orelse break :blk false;
            const y = (model.reference(b) orelse break :blk false).declaration orelse break :blk false;
            break :blk x == y;
        },
        .field_access => std.mem.eql(u8, tree.tokenSlice(tree.nodeData(a).node_and_token[1]), tree.tokenSlice(tree.nodeData(b).node_and_token[1])) and
            typedAlike(tree, model, tree.nodeData(a).node_and_token[0], tree.nodeData(b).node_and_token[0], depth + 1),
        .unwrap_optional, .grouped_expression => typedAlike(tree, model, tree.nodeData(a).node_and_token[0], tree.nodeData(b).node_and_token[0], depth + 1),
        .deref, .@"try" => typedAlike(tree, model, tree.nodeData(a).node, tree.nodeData(b).node, depth + 1),
        .array_access => typedAlike(tree, model, tree.nodeData(a).node_and_node[0], tree.nodeData(b).node_and_node[0], depth + 1),
        .call_one, .call_one_comma => tree.nodeData(a).node_and_opt_node[1] == .none and tree.nodeData(b).node_and_opt_node[1] == .none and
            typedAlike(tree, model, tree.nodeData(a).node_and_opt_node[0], tree.nodeData(b).node_and_opt_node[0], depth + 1),
        else => false,
    };
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
    // Whether the program uses `x.name` as a truth value, a number or an operand of a comparison.
    var operand = false;
    // Whether the program calls `x.name(...)`: a method, or a field that holds a function.
    var called = false;
    if (model.parentOf(field)) |parent| {
        if (tree.nodeTag(parent) == .field_access and tree.nodeData(parent).node_and_token[0] == field)
            member = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(parent).node_and_token[1]));
        operand = scalarOperand(tree, parent, field);
        var call_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&call_buffer, parent)) |call| called = call.ast.fn_expr == field;
    }
    // The fields `x`'s literal initializer names.
    var literal_buffer: [2]Ast.Node.Index = undefined;
    var literal: ?Ast.full.StructInit = null;
    const receiver = tree.nodeData(field).node_and_token[0];
    if (tree.nodeTag(receiver) == .identifier) if (model.reference(receiver)) |ref| if (ref.declaration) |index| {
        if (tree.fullVarDecl(model.declarations[@backingInt(index)].node)) |v| if (v.ast.init_node.unwrap()) |init| {
            if (tree.fullStructInit(&literal_buffer, init)) |value| if (value.ast.type_expr == .none) {
                literal = value;
            };
        };
    };
    const siblings = try receiverMembers(c, tree, model, receiver, name);
    if (siblings.len != 0 and try noLibraryHolder(c, name, siblings)) return true;
    if (member == null and literal == null and !operand and !called) return false;
    const found = try c.facts.publication(Contract.library);
    var any = false;
    for (found.entries) |entry| {
        const k: Contract.Kind = @fromBackingInt(@intCast(entry.role));
        if (!backing(k, name)) continue;
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
                    else => return false,
                };
                continue;
            }
            const holder = switch (declared) {
                .container, .instance => |held| held,
                .array => if (sequence) return false else continue,
                .primitive, .scalar => continue,
                .pointer => |to| switch (to.*) {
                    .container, .instance => |held| held,
                    .array, .primitive, .scalar => if (sequence) return false else continue,
                    else => return false,
                },
                else => return false,
            };
            if (c.facts.member(holder, read) != null) return false;
        } else {
            // A struct (not packed) is no truth value, number or comparable operand: an
            // atomic, a mutex or a condition used as one is not this field.
            const held = switch (declared) {
                .container, .instance => |held| held,
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
        .pointer, .optional => |inner| callable(inner.*, depth + 1),
        .alternatives => |each| for (each) |one| {
            if (callable(one, depth + 1)) break true;
        } else false,
        else => true,
    };
}

/// Whether `parent` uses its child `field` as a truth value (a condition, an operand of
/// `and`, `or` or `!`), an operand of a comparison or of arithmetic.
fn scalarOperand(tree: *const Ast, parent: Ast.Node.Index, field: Ast.Node.Index) bool {
    switch (tree.nodeTag(parent)) {
        .bool_not, .negation => return true,
        .bool_and, .bool_or, .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .add, .sub, .mul, .div, .mod => return true,
        else => {},
    }
    if (tree.fullIf(parent)) |full| return full.ast.cond_expr == field and full.payload_token == null and full.error_token == null;
    if (tree.fullWhile(parent)) |full| return full.ast.cond_expr == field and full.payload_token == null and full.error_token == null;
    return false;
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
fn publishedContainer(c: *Context, target: Facts.Target) Context.Error!?Facts.Container {
    switch (target) {
        .container => |container| return container,
        .function => |function| {
            if (try c.facts.template(function)) |made| switch (made) {
                .container, .instance => |container| return container,
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

/// Whether `name` is a backing field of a published type of kind `k`: the one place the
/// contract's field catalogue (`backingFields`) is read by name.
fn backing(k: Contract.Kind, name: []const u8) bool {
    for (backingFields(k)) |field| if (std.mem.eql(u8, name, field)) return true;
    return false;
}

/// The private state of the published types: the secret's material, the bytes' allocation, the
/// guards' value and lock state, and after them what each type's source keeps
/// behind its operations (the initialized prefix and its cursors, a budget's charge, an owner's
/// payload and witness, a loan's copy, a staged payload, a machine's state, a scope's record,
/// the checked pointer, the unparsed value, the decision bit).
fn backingFields(k: Contract.Kind) []const []const u8 {
    return switch (k) {
        .secret => &.{"material"},
        .bytes => &.{ "allocation", "used_len", "gpa" },
        // The guarded value and the lock state of every guarded owner: a spin flag, a
        // blocking mutex, a reader-writer lock and its admission count. An ordered owner's
        // base lock too.
        .guarded => &.{ "data", "lock", "mutex", "state", "admitted", "base" },
        // A guard's owner; an ordered guard's base guard.
        .guard => &.{ "owner", "base" },
        // A value initialized once: its publication state, its election lock and waiters, and
        // the value itself before the state says it is there.
        .once => &.{ "state", "mutex", "changed", "data" },
        // A value one logical task owns: the value and the identity that is checked.
        .confined => &.{ "data", "owner" },
        .inline_store => &.{ "storage", "used", "head" },
        .buffer => &.{ "storage", "gpa", "maximum", "used", "head" },
        .limit => &.{"maximum"},
        .budget => &.{ "ceiling", "taken", "unsettled" },
        .reservation => &.{ "budget", "amount", "live" },
        .owned => &.{ "data", "state" },
        .lent => &.{"data"},
        .must_use => &.{ "data", "pending", "live" },
        .shared => &.{ "block", "live" },
        .slots => &.{ "slots", "storage", "primary", "values", "keys", "free_head", "entries" },
        .stage => &.{ "live", "payload" },
        .machine => &.{"state"},
        .table => &.{ "slots", "free_head", "used_up", "open_count" },
        .scope => &.{ "table", "generation", "index" },
        .ref => &.{ "slot", "generation", "pointer" },
        .untrusted => &.{"value"},
        .choice => &.{"bit"},
        .atomic => &.{"cell"},
        .context => &.{ "stack", "used", "suspended", "owners" },
        else => &.{},
    };
}

/// Whether `name` is a backing field of any published type.
fn backingName(name: []const u8) bool {
    for (std.enums.values(Contract.Kind)) |k| if (backing(k, name)) return true;
    return false;
}

/// Whether a copy of a value of kind `k` is a second owner: every published type but the
/// copyable values (scalars, decisions, scopes and their references, limits, unparsed views,
/// loans) and inline storage, whose copy is its elements' (A002 does not read the element type).
fn copiedOwner(k: Contract.Kind) bool {
    return switch (k) {
        .scalar, .choice, .scope, .ref, .limit, .untrusted, .inline_store, .public_source, .lent => false,
        else => true,
    };
}

/// What ends a local owner's obligation, by kind: its release, or a declared transfer that
/// moves it into storage the caller names. Null for kinds with no cleanup to owe.
fn releases(k: Contract.Kind) ?[]const []const u8 {
    return switch (k) {
        .secret, .bytes => &.{ "deinit", "moveInto" },
        .guard, .buffer, .slots, .table => &.{"deinit"},
        .handoff => &.{"release"},
        .reservation => &.{ "release", "consume", "moveInto" },
        .owned => &.{ "deinit", "take", "moveInto" },
        // A std resource held raw: `close`, a child's `kill` or `wait`.
        .std_handle => &.{ "close", "kill", "wait" },
        // A result obligation is discharged by taking it or acknowledging it with a reason;
        // its `deinit` checks that it was.
        .must_use => &.{ "take", "acknowledge" },
        .shared => &.{"release"},
        .scope => &.{"end"},
        else => null,
    };
}

/// What checks a local owner's obligation once it is discharged, by kind: a result
/// obligation's `deinit`, which stops the program unless `take` or `acknowledge` came first.
fn teardown(k: Contract.Kind) ?[]const u8 {
    return switch (k) {
        .must_use => "deinit",
        else => null,
    };
}

fn releaseName(k: Contract.Kind, name: []const u8) bool {
    for (releases(k) orelse return false) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
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
    // A type chosen at compile time is one type per build: an operation on it is the
    // owner's in the builds that choose the owner. Cleanup is owed along the paths of those
    // builds, which are every path unless the function branches on a comptime condition
    // (`if (wrapped) owner.deinit();`); then A003 leaves a choice that disagrees undecided.
    const found = if (rule != cleanup or !try c.facts.branchesOnCondition(c.file, node)) try perBuild(c, value) else try typed(c, value, 0);
    // An owner held in a record's field is A003's too, though the record is no owner.
    if (rule == cleanup and found == .other) return heldInRecord(c, value, 0);
    return found;
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
        .pointer, .array, .optional, .error_union => |payload| payload.*,
        .reified => |built| built.fields.*,
        else => break,
    };
    if (current != .alternatives) return typed(c, value, 0);
    var found: Typed = .other;
    for (current.alternatives) |one| found = joined(found, try typed(c, one, 0));
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
        else => typed(c, value, depth + 1),
    };
}
/// The role of the published aegis type `container` is declared inside, as a guarded value's
/// guard is: its own operations belong to that type's contract.
fn enclosingPublished(c: *Context, container: Facts.Container) Context.Error!?Contract.Kind {
    const found = try c.facts.publication(Contract.library);
    const scopes = c.project.at(container.file).model.scopes;
    var scope = scopes[@backingInt(container.scope)].parent;
    while (scope) |s| : (scope = scopes[@backingInt(s)].parent) {
        for (found.entries) |entry| if (entry.target == .container and entry.target.container.file == container.file and entry.target.container.scope == s) return @fromBackingInt(@intCast(entry.role));
    }
    return null;
}
/// The name a container is declared under (`pub const Guard = struct { ... }`), if any.
fn containerName(c: *Context, container: Facts.Container) ?[]const u8 {
    const model = &c.project.at(container.file).model;
    const tree = &c.project.at(container.file).file.tree;
    const node = model.scopes[@backingInt(container.scope)].node;
    if (node == .root) return null;
    const parent = model.parentOf(node) orelse return null;
    const declared = tree.fullVarDecl(parent) orelse return null;
    return tree.tokenSlice(declared.ast.mut_token + 1);
}
/// What a resolved value's type says: a published aegis type, a type that is not aegis, or
/// unknown. A guarded owner's guard is the guard. Another type declared inside a published one
/// and not in the contract is plain data, as an unlisted type at a module's top is: the
/// contract lists every type whose fields are private state (`Budget.Reservation`,
/// `Table.Scope`), and the state such a type holds for its owner (a map's entries, a shared
/// owner's block) is reached through the owner's backing field, which is read there. A choice
/// between types that disagree stays unknown.
fn typed(c: *Context, value: Facts.Value, depth: usize) Context.Error!Typed {
    if (depth == 64) return .unknown;
    return switch (value) {
        // What std computes from the program and target it is in is std's own: std declares
        // no aegis type, so it plays no aegis role. Code the build does not compile holds none.
        .unknown => |why| switch (why) {
            .zig_own, .absent => .other,
            else => .unknown,
        },
        .pointer, .array, .optional, .error_union => |payload| typed(c, payload.*, depth + 1),
        // A built type holds what its fields' types do.
        .reified => |built| typed(c, built.fields.*, depth + 1),
        .alternatives => |each| blk: {
            const first = try typed(c, each[0], depth + 1);
            for (each[1..]) |one| if (!std.meta.eql(first, try typed(c, one, depth + 1))) break :blk .unknown;
            break :blk first;
        },
        // An anonymous literal holds what its fields or elements do: one owner among plain
        // parts is that owner's, as a copy of the literal copies it.
        .literal => |literal| blk: {
            var found: Typed = .other;
            for (try c.facts.literalParts(literal)) |part| found = joined(found, try typed(c, part, depth + 1));
            break :blk found;
        },
        .container, .instance => |container| blk: {
            if (try c.role(Contract.library, value)) |k| break :blk .{ .owner = k };
            const outer = (try enclosingPublished(c, container)) orelse break :blk .other;
            // A guarded owner's guard, reached by its resolved type rather than its acquisition.
            if (outer == .guarded and Contract.guardType(containerName(c, container) orelse "")) break :blk .{ .owner = .guard };
            // A guard's release handed past its frame, released once as the guard is.
            if (outer == .guarded and Contract.handoffType(containerName(c, container) orelse "")) break :blk .{ .owner = .handoff };
            break :blk .other;
        },
        else => .other,
    };
}
/// What A003 owes of a value its type reads as plain data: nothing, unless a record of the
/// program holds an owner by value in a field (Facts.heldFields), through an array, an optional
/// and an error union (`struct { guard: L.Guard, count: u32 }` a helper returns, `struct {
/// L.Guard, u32 }`), or a field that does not resolve may hold one: unknown, as A003 follows no
/// owner held in a field. A pointer field borrows; aegis's own types hold what their contract
/// says.
fn heldInRecord(c: *Context, value: Facts.Value, depth: usize) Context.Error!Typed {
    if (depth == 64) return .unknown;
    var current = value;
    while (true) current = switch (current) {
        .array, .optional, .error_union => |inner| inner.*,
        else => break,
    };
    const container = switch (current) {
        .instance => |container| container,
        else => return .other,
    };
    if (try c.inLibrary(Contract.library, container.file)) return .other;
    // std's records (`std.EnumSet(E).Iterator`) are none of the program's: their own fields
    // are std's internals, read as their types say.
    if (!try c.facts.program(container.file)) return .other;
    for (try c.facts.heldFields(container)) |field| {
        if (field.value == .pointer) continue;
        // A field typed only by a generic's binding (`state: State` of `Layer(State, ...)`):
        // what the binding gives is judged where it is bound (`checkBinding`).
        if (bindingTyped(field.value)) continue;
        if (try typed(c, field.value, depth + 1) != .other) return .unknown;
        if (try heldInRecord(c, field.value, depth + 1) != .other) return .unknown;
    }
    return .other;
}
/// Whether a value is unknown only because a generic's binding gives its type.
fn bindingTyped(value: Facts.Value) bool {
    var current = value;
    while (true) current = switch (current) {
        .pointer, .array, .optional, .error_union => |inner| inner.*,
        .unknown => |why| return why == .generic,
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
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, node) orelse return;
    const name_token = switch (tree.nodeTag(call.ast.fn_expr)) {
        .identifier => tree.nodeMainToken(call.ast.fn_expr),
        .field_access => tree.nodeData(call.ast.fn_expr).node_and_token[1],
        else => return,
    };
    const spelled = try Model.identifier(c.allocator, tree.tokenSlice(name_token));
    switch (try c.facts.copiesBy(spelled)) {
        .none => return,
        // A generic that only moves a parameter into storage copies for A002 alone, and only
        // what does not move at the call.
        .moves => if (rule != copies or try argumentsMove(c, call)) return,
        .copies => {},
    }
    // Each function it may call is bound by it; a callee spelled as a copying generic that
    // does not resolve may be one.
    const functions: []const Facts.Decl = switch ((try Facts.calls.at(c.facts, c.file, node) orelse return).callee) {
        .function => |function| &.{function},
        .choice => |each| each,
        .any => {
            // A call through a function pointer (`rule.check(&context)`): no generic, whose
            // parameters a runtime function's type cannot take, is called there.
            const callee = try c.facts.resolve(c.file, call.ast.fn_expr);
            if (callee == .fn_type or (callee == .pointer and callee.pointer.* == .fn_type)) return;
            return c.undecided(rule, tree.tokenStart(name_token), .unresolved, "a call spelled as a generic that copies its parameters does not resolve: its binding may copy an owner");
        },
    };
    for (functions) |function| if (try boundBy(c, tree, node, call, rule, function, name_token)) return;
}

/// Whether every argument of `call` moves at it: made in place, or a local nothing holds beside
/// the call (`moved`).
fn argumentsMove(c: *Context, call: Ast.full.Call) Context.Error!bool {
    for (call.ast.params) |argument| {
        const parts = try c.facts.copiedParts(c.file, argument);
        if (parts.deep != null) return false;
        for (parts.places) |place| if (try moved(c, argument, place, false) != .yes) return false;
    }
    return true;
}

/// `checkBinding` of `function`, one the call at `node` may call: whether it reported a copy.
fn boundBy(c: *Context, tree: *const Ast, node: Ast.Node.Index, call: Ast.full.Call, rule: Rule, function: Facts.Decl, name_token: Ast.TokenIndex) Context.Error!bool {
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
        types[count] = if (param.type_expr) |t| written.nodeTag(t) == .identifier and std.mem.eql(u8, written.tokenSlice(written.nodeMainToken(t)), "type") else false;
        values[count] = param.anytype_ellipsis3 != null;
    }
    const receiver: usize = if (tree.nodeTag(call.ast.fn_expr) == .field_access and count == call.ast.params.len + 1) 1 else 0;
    // The generic's casts this binding makes an aegis scalar's: one finding at the binding,
    // naming each, however many of the generic's paths and instances reach it.
    var casts: std.ArrayList(Report.Span) = .empty;
    for (made) |copy| {
        // A cast by a parameter's type is A004's; a copy A002's, an acquisition A003's.
        if ((copy.kind == .cast) != (rule == scalar)) continue;
        if (copy.kind != .cast and (copy.kind == .made) != (rule == cleanup)) continue;
        if (copy.kind == .made and !try acquiring(c, copy.site)) continue;
        if (copy.position < receiver or copy.position - receiver >= call.ast.params.len) continue;
        if (!types[copy.position] and !values[copy.position]) continue;
        const argument = call.ast.params[copy.position - receiver];
        // A parameter of a generic this call is in, passed on: decided where that is bound.
        if (c.facts.fromParameter(c.file, argument)) continue;
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
        const value = if (copy.crowded)
            Facts.Value{ .unknown = .budget }
        else if (copy.source != null)
            try c.facts.boundCopy(c.file, call, receiver == 1, function, copy)
        else if (if (types[copy.position]) try plainType(c, c.file, argument, 0) else try plainValue(c, c.file, argument, 0))
            continue
        else
            try c.facts.resolve(c.file, argument);
        if (copy.kind == .cast) {
            // The library's own generics are its safe types' internals.
            if (try c.inLibrary(Contract.library, copy.site.file)) continue;
            switch (try perBuild(c, try instanceOf(c, value))) {
                .owner => |k| if (k == .scalar) {
                    const span = c.spanOf(copy.site.file, c.project.at(copy.site.file).file.tree.nodeMainToken(copy.site.node));
                    for (casts.items) |known| {
                        if (known.file == span.file and known.start == span.start) break;
                    } else try casts.append(c.allocator, span);
                },
                .other => {},
                .unknown => if (!bindingTyped(value)) try c.undecided(scalar, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a generic that casts integers by its parameter's type is bound to a type that does not resolve"),
            }
            continue;
        }
        // A pointer type: its copies are aliases, which A002 leaves out.
        if (pointerShaped(value)) continue;
        // A type argument stands for its values.
        const bound = switch (value) {
            .container => |container| Facts.Value{ .instance = container },
            else => value,
        };
        if (copy.kind == .made) {
            const site = c.project.at(copy.site.file).file;
            const line = site.line(site.tree.tokenStart(site.tree.firstToken(copy.site.node))) + 1;
            switch (try perBuild(c, bound)) {
                .owner => |k| if (releases(k) != null) try c.undecided(cleanup, tree.tokenStart(tree.nodeMainToken(node)), .unsupported, try c.allocator.print("this binding makes an owner of what {s}:{d} acquires by the generic's type parameter; its cleanup is not walked per binding", .{ c.project.at(copy.site.file).input.name, line })),
                .other => {},
                .unknown => if (!bindingTyped(bound)) try c.undecided(cleanup, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a generic that acquires by its type parameter is bound to a type that does not resolve"),
            }
            continue;
        }
        switch (try copied(c, bound, 0)) {
            .owner => |k| if (copiedOwner(k)) {
                const site = c.project.at(copy.site.file).file;
                const detail = try c.allocator.print("this binding makes a recognized owner of a generic's parameter, which {s}:{d} copies; a duplicated owner requires explicit transfer", .{ c.project.at(copy.site.file).input.name, site.line(site.tree.tokenStart(site.tree.firstToken(copy.site.node))) + 1 });
                try c.at(copies, tree.nodeMainToken(node), detail);
                return true;
            },
            .other => {},
            .unknown => if (!bindingTyped(bound)) try c.undecided(copies, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a generic that copies its parameter is bound to a type that does not resolve"),
        }
    }
    if (casts.items.len == 0) return false;
    var named: std.ArrayList(u8) = .empty;
    for (casts.items, 0..) |span, i| {
        if (i != 0) try named.appendSlice(c.allocator, if (i + 1 == casts.items.len) " and " else ", ");
        try named.print(c.allocator, "{s}:{d}", .{ c.project.at(span.file).input.name, span.line });
    }
    const message = if (casts.items.len == 1)
        try c.allocator.print("this binding makes the integer {s} makes or reads by the generic's type an aegis scalar's, outside its checked construction and arithmetic", .{named.items})
    else
        try c.allocator.print("this binding makes the integers {s} make or read by the generic's type aegis scalars', outside their checked construction and arithmetic", .{named.items});
    const at = tree.tokenToSpan(tree.nodeMainToken(node));
    try c.emitRelated(scalar, at.start, at.end, message, casts.items);
    return true;
}

fn checkCopies(c: *Context) Context.Error!void {
    if (!try begin(c, copies)) return;
    const tree = try c.project.syntax(try c.source());
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        try checkBinding(c, tree, node, copies);
        if (tree.fullVarDecl(node)) |v| {
            const init = v.ast.init_node.unwrap() orelse continue;
            // A container's `const` is known as the program compiles and never changes: no
            // release or consume (each takes `*Self`) reaches it or what it names, so it
            // duplicates no live owner.
            if (tree.tokenTag(v.ast.mut_token) == .keyword_const and containerLevel(c, tree, node)) continue;
            try checkCopy(c, tree, node, init, v.ast.type_node.unwrap());
        }
        // A destructure copies what its value reads, as a declaration does; a copy of bytes
        // copies the memory it reads (`@memcpy(dst, std.mem.asBytes(&owner))`).
        if (tag == .assign_destructure) try checkCopy(c, tree, node, tree.assignDestructure(node).ast.value_expr, null);
        // An exchange (`std.mem.swap`) moves each into the other: no second holder.
        if (try Facts.accesses.copyAt(c.facts, c.file, node)) |copy| if (!copy.exchange) try checkCopy(c, tree, node, copy.from.node(), null);
        if (tag == .assign) {
            const sides = tree.nodeData(node).node_and_node;
            // `_ = x` discards the value: no second holder.
            if (tree.nodeTag(sides[0]) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(sides[0])), "_")) continue;
            try checkCopy(c, tree, node, sides[1], null);
            try checkStoredBorrow(c, tree, node, sides[0], sides[1]);
        }
        if (tag == .@"return") {
            const expr = tree.nodeData(node).opt_node.unwrap() orelse continue;
            // What it gives is a copy, as a declaration's value is, into the result the
            // function declares (a type function's `type`, plain data).
            var proto_buffer: [1]Ast.Node.Index = undefined;
            const result = if (enclosingFunction(tree, &c.project.at(c.file).model, node)) |function| tree.fullFnProto(&proto_buffer, function).?.ast.return_type.unwrap() else null; // unreachable: a `fn_decl` has a prototype
            try checkCopy(c, tree, node, expr, result);
            var walk: Exposure = .{ .c = c };
            if (try walk.carries(expr, 0)) {
                try c.at(copies, tree.nodeMainToken(node), "returned secret/guard borrow can outlive its capability; caller lifetime is undecided");
            } else if (walk.cut) {
                try c.undecided(copies, tree.tokenStart(tree.nodeMainToken(node)), .unsupported, "what this returns is nested past the depth A002 follows: a borrow it carries is not ruled out");
            } else if (walk.unknown) |at| try c.undecided(copies, tree.tokenStart(tree.nodeMainToken(at)), .unsupported, "a call or builtin given a secret/guard borrow may give it back: a borrow this returns is not ruled out");
        }
    }
}

/// A copy made by `copy`, a declaration, an assignment or a `return`, of each value `init` may
/// give (`copiedValue`). Plain data, as the copy is declared, holds no owner.
fn checkCopy(c: *Context, tree: *const Ast, copy: Ast.Node.Index, init: Ast.Node.Index, type_node: ?Ast.Node.Index) Context.Error!void {
    if (type_node) |t| if (try plainType(c, c.file, t, 0)) return;
    try copiedValue(c, tree, copy, init);
}

/// Each value `copy` copies from `init`, as `Facts.copiedParts` follows it: a place is a copy
/// of what it reads (`copiedPlace`); a call makes its value, which its own `return` copies; any
/// other shape is decided by its type, undecided where it may be an owner, as is a value
/// nested past the depth followed.
fn copiedValue(c: *Context, tree: *const Ast, copy: Ast.Node.Index, init: Ast.Node.Index) Context.Error!void {
    const parts = try c.facts.copiedParts(c.file, init);
    if (parts.deep) |node| try c.undecided(copies, tree.tokenStart(tree.nodeMainToken(node)), .unsupported, "a copy's value is nested past the depth A002 follows: an owner it copies is not ruled out");
    for (parts.places) |place| try copiedPlace(c, tree, copy, init, place);
    for (parts.rest) |node| {
        if (try plainValue(c, c.file, node, 0)) continue;
        // Another shape (an operator's, a builtin's): decided by what its value's type is.
        switch (try perBuild(c, try c.facts.resolve(c.file, node))) {
            .other => {},
            .owner => |k| if (copiedOwner(k)) try c.undecided(copies, tree.tokenStart(tree.nodeMainToken(node)), .unsupported, "a copy's value may be a recognized owner by a way A002 does not follow"),
            .unknown => try c.undecided(copies, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a copy's value does not resolve to a type, and may be a recognized owner"),
        }
    }
}

/// A copy of the value read from a place: a name, a field, `@field`, what a pointer points at,
/// an element or an optional's payload.
fn copiedPlace(c: *Context, tree: *const Ast, copy: Ast.Node.Index, init: Ast.Node.Index, node: Ast.Node.Index) Context.Error!void {
    const root = placeRoot(tree, node) orelse try sharedReturn(c, tree, node) orelse return;
    const model = &c.project.at(c.file).model;
    // `undefined`, `true`, `false` and `null` are values, not references to an owner.
    if (root == node and model.reference(node) == null) return;
    // A container's `const`, known as the program compiles: no release or consume reaches
    // it, so a copy of it duplicates no live owner.
    if (root == node) if (Contract.local(c, node)) |index| {
        const decl = model.declarations[@backingInt(index)];
        if (decl.kind == .variable and tree.tokenTag(tree.fullVarDecl(decl.node).?.ast.mut_token) == .keyword_const and containerLevel(c, tree, decl.node)) return; // unreachable: a variable's node is its declaration
    };
    // A `return` of the function's own local moves it, whatever it holds.
    const returned = tree.nodeTag(copy) == .@"return";
    // Why the copy may be a move, where it is not known to be one.
    var unmoved: ?Facts.Unknown = null;
    if (returned and tree.nodeTag(node) == .identifier) switch (try moved(c, copy, node, true)) {
        .yes => return,
        .no => {},
        .unknown => |why| unmoved = why,
    };
    // A value of a generic's parameter, or read from one: each binding's copy, checked at
    // the binding, where every binding is a call a run judges.
    if (root == node and try c.facts.parameterAtBinding(c.file, node)) return;
    if (try c.facts.boundAtBinding(c.file, copy, node)) return;
    // A `comptime` parameter's value, or a part of it, known as the program compiles: it
    // holds nothing at run time.
    if (c.facts.comptimeParameter(c.file, root)) return;
    // Plain data, as its source is declared, holds no owner: the copy is decided.
    if (try plainValue(c, c.file, node, 0)) return;
    // A copied pointer is an alias, which this rule leaves out, whatever it points at.
    const value = try c.facts.resolve(c.file, node);
    if (pointerShaped(value)) return;
    // An owner itself, or a struct, union or tuple of the program's holding one in a field.
    const k = (try requiredOwner(c, node, copies, tree.nodeMainToken(node))) orelse switch (try fieldOwner(c, value, 0)) {
        .owner => |held| held,
        .other => return,
        .unknown => return c.undecided(copies, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a copy of a value whose fields do not all resolve may copy a recognized owner"),
    };
    if (!copiedOwner(k)) return;
    switch (heldAs(value)) {
        .value => {},
        // A type, a function or a namespace names no owner's value: `const S = Secret(u32);`.
        .type => return,
        // An owner as written where it comes from; else what it is stays undecided.
        .unknown => if (!try ownedValue(c, node, 0)) {
            try c.undecided(copies, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a copy of what may be a recognized owner does not resolve to a value or a type");
            return;
        },
    }
    // A local nothing reads after the copy, deferred code included, is moved, not
    // duplicated: `var guard = free;` out of an `if` capture. A `return` ends the function's
    // locals, of any kind: what it gives is moved unless a deferred read or a copy made before
    // it holds the owner too.
    if (!returned and movable(k) and tree.nodeTag(node) == .identifier) switch (try moved(c, copy, node, false)) {
        .yes => return,
        .no => {},
        .unknown => |why| unmoved = why,
    };
    if (unmoved) |why| return c.unknown(copies, node, why);
    const at = if (node == init) tree.nodeMainToken(copy) else tree.firstToken(node);
    try c.at(copies, at, "copy of a recognized live owner/capability requires explicit transfer; lifetime and publication are undecided");
}

/// The owner a value of a struct, union or tuple the program declares holds by value in a
/// field, or in a field's field: a copy of the whole copies it. A pointer field is an alias.
/// Unknown where a field's type does not resolve, or fields nest past the depth followed.
fn fieldOwner(c: *Context, value: Facts.Value, depth: usize) Context.Error!Typed {
    if (depth == 16) return .unknown;
    const container = switch (value) {
        .array, .optional, .error_union => |inner| return fieldOwner(c, inner.*, depth + 1),
        .instance, .container => |container| container,
        else => return .other,
    };
    switch (try typed(c, value, 0)) {
        .other => {},
        else => |found| return found,
    }
    const model = &c.project.at(container.file).model;
    const tree = &c.project.at(container.file).file.tree;
    const node = model.scopes[@backingInt(container.scope)].node;
    var buffer: [2]Ast.Node.Index = undefined;
    const members = if (node == .root) tree.rootDecls() else blk: {
        const decl = tree.fullContainerDecl(&buffer, node) orelse return .other;
        // An enum's or an opaque's members hold no fields' values.
        switch (tree.tokenTag(decl.ast.main_token)) {
            .keyword_struct, .keyword_union => {},
            else => return .other,
        }
        break :blk decl.ast.members;
    };
    var found: Typed = .other;
    for (members) |member| {
        const field = model.containerField(tree, member) orelse continue;
        // A union's field with no type holds `void`.
        const t = field.ast.type_expr.unwrap() orelse continue;
        const held = try c.facts.resolve(container.file, t);
        if (pointerShaped(held)) continue;
        switch (try fieldOwner(c, held, depth + 1)) {
            .owner => |k| if (copiedOwner(k)) return .{ .owner = k },
            .other => {},
            .unknown => found = .unknown,
        }
    }
    return found;
}

/// Whether a declaration is a container's member: a file's or a struct's, not a body's.
fn containerLevel(c: *Context, tree: *const Ast, node: Ast.Node.Index) bool {
    const parent = c.project.at(c.file).model.parentOf(node) orelse return true;
    if (tree.nodeTag(parent) == .root) return true;
    var buffer: [2]Ast.Node.Index = undefined;
    return tree.fullContainerDecl(&buffer, parent) != null;
}

/// The name a place is read through (`s` of `s`, `h.s`, `@field(h, "s")`, `p.*`, `a[0]`,
/// `a[0..1].*`, `o.?`), or null for a value made in place (a call, a literal, an operator),
/// which no other holder shares.
fn placeRoot(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    var current = node;
    while (true) current = switch (tree.nodeTag(current)) {
        .identifier => return current,
        .field_access, .unwrap_optional, .grouped_expression => tree.nodeData(current).node_and_token[0],
        .deref => tree.nodeData(current).node,
        .array_access, .slice_open => tree.nodeData(current).node_and_node[0],
        .slice => tree.nodeData(current).node_and_extra[0],
        .slice_sentinel => tree.nodeData(current).node_and_extra[0],
        .builtin_call_two, .builtin_call_two_comma => blk: {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(current)), "@field")) return null;
            break :blk tree.nodeData(current).opt_node_and_opt_node[0].unwrap() orelse return null;
        },
        else => return null,
    };
}

/// What a place read off a call's result is read through, where the call gives a pointer
/// another holder shares (`it.next().?.*`, `map.getPtr(k).?.owner`): the call, standing for
/// the place's root. Null where every step reads the value the call makes, which no other
/// holder shares; a step whose operand does not resolve may be through a pointer.
fn sharedReturn(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    var shared = false;
    var current = node;
    while (true) {
        const operand = switch (tree.nodeTag(current)) {
            .deref => {
                shared = true;
                current = tree.nodeData(current).node;
                continue;
            },
            .unwrap_optional, .grouped_expression, .field_access => tree.nodeData(current).node_and_token[0],
            .array_access, .slice_open => tree.nodeData(current).node_and_node[0],
            .slice, .slice_sentinel => tree.nodeData(current).node_and_extra[0],
            // A type's member (`@TypeOf(x).Role`): no value is read.
            else => return if (shared and !typeBuiltin(tree, current)) current else null,
        };
        // A field or an element read through a pointer dereferences it.
        switch (tree.nodeTag(current)) {
            .field_access, .array_access, .slice_open, .slice, .slice_sentinel => switch (try c.facts.resolve(c.file, operand)) {
                .pointer, .unknown => shared = true,
                else => {},
            },
            else => {},
        }
        current = operand;
    }
}

/// Whether `node` is a builtin call that gives a type.
fn typeBuiltin(tree: *const Ast, node: Ast.Node.Index) bool {
    for ([_][]const u8{ "@TypeOf", "@This", "@import", "@typeInfo", "@Type", "@FieldType" }) |name| {
        if (Facts.isBuiltin(tree, node, name)) return true;
    }
    return false;
}

const Held = enum { value, type, unknown };

/// Whether a resolved value is a value a copy duplicates, or a type, function or namespace,
/// which holds none.
fn heldAs(value: Facts.Value) Held {
    return switch (value) {
        .instance, .array, .optional, .error_union => .value,
        .reified => |built| if (built.value) .value else .type,
        .container, .function, .primitive, .fn_type, .error_set => .type,
        .alternatives => |each| blk: {
            var found: ?Held = null;
            for (each) |one| {
                const next = heldAs(one);
                if (found != null and found.? != next) break :blk .unknown;
                found = next;
            }
            break :blk found orelse .unknown;
        },
        else => .unknown,
    };
}

/// A borrow stored where it outlives the function: in memory a parameter or a container's
/// variable reaches, or through a pointer a local holds. A local's own value, whole or in a
/// part, is followed where it is returned.
fn checkStoredBorrow(c: *Context, tree: *const Ast, store: Ast.Node.Index, target: Ast.Node.Index, value: Ast.Node.Index) Context.Error!void {
    const root = placeRoot(tree, target) orelse return;
    const model = &c.project.at(c.file).model;
    const ref = model.reference(root) orelse return;
    // A root whose declaration does not resolve may be a parameter's or a container's memory.
    const outer = if (ref.declaration) |index| blk: {
        const decl = model.declarations[@backingInt(index)];
        break :blk decl.kind == .parameter or (decl.kind == .variable and containerLevel(c, tree, decl.node));
    } else true;
    // A local's own storage, unless it holds a pointer the store goes through.
    if (!outer and (root == target or !pointerShaped(try c.facts.resolve(c.file, root)))) return;
    var walk: Exposure = .{ .c = c };
    if (try walk.carries(value, 0)) {
        if (ref.declaration == null) return c.undecided(copies, tree.tokenStart(tree.nodeMainToken(store)), .unresolved, "a secret/guard borrow stored where the place does not resolve may outlive its capability");
        if (outer) return c.at(copies, tree.nodeMainToken(store), "stored secret/guard borrow can outlive its capability; caller lifetime is undecided");
        return c.undecided(copies, tree.tokenStart(tree.nodeMainToken(store)), .unsupported, "a secret/guard borrow stored through a pointer a local holds may outlive its capability");
    }
    if (walk.cut) return c.undecided(copies, tree.tokenStart(tree.nodeMainToken(store)), .unsupported, "what this stores is nested past the depth A002 follows: a borrow it carries is not ruled out");
    if (walk.unknown) |at| return c.undecided(copies, tree.tokenStart(tree.nodeMainToken(at)), .unsupported, "a call or builtin given a secret/guard borrow may give it back: a borrow this stores is not ruled out");
}

/// Whether a value carries a borrow of a secret or a guard's value: the borrow itself; a
/// branch, prong, `break` or `else` that gives the value; a builtin that keeps its operand's
/// address (`@as`, `@ptrCast`, `@alignCast`, `@constCast`, `@bitCast`, `@field`,
/// `@unionInit`); a slice of it, or an address of a part read through it; a part (a field, an
/// element, a payload, what it points at) that may itself be a pointer; a field or element of a
/// literal; a capture of it; or a local it was put in, whole or in a part. Each local is read
/// once: a search for any borrow learns nothing more from a local already followed (`head =
/// head orelse x`). A call given a borrow may return it: `unknown` names one whose result may be
/// a pointer, as it does a shape not followed; past the depth it follows, `cut` says so. Neither
/// is cleared.
const Exposure = struct {
    c: *Context,
    seen: std.AutoHashMapUnmanaged(Model.Declaration.Id, void) = .empty,
    cut: bool = false,
    unknown: ?Ast.Node.Index = null,

    fn carries(e: *Exposure, node: Ast.Node.Index, depth: usize) Context.Error!bool {
        const c = e.c;
        if (depth == 256) {
            e.cut = true;
            return false;
        }
        const tree = try c.project.syntax(try c.source());
        const model = &c.project.at(c.file).model;
        switch (tree.nodeTag(node)) {
            .grouped_expression => return e.carries(tree.nodeData(node).node_and_token[0], depth + 1),
            .@"try", .@"comptime", .@"nosuspend" => return e.carries(tree.nodeData(node).node, depth + 1),
            .@"orelse", .@"catch" => {
                const sides = tree.nodeData(node).node_and_node;
                return try e.carries(sides[0], depth + 1) or try e.carries(sides[1], depth + 1);
            },
            .@"if", .if_simple => {
                const branch = tree.fullIf(node).?; // unreachable: the tag is an `if`'s
                if (try e.carries(branch.ast.then_expr, depth + 1)) return true;
                const otherwise = branch.ast.else_expr.unwrap() orelse return false;
                return e.carries(otherwise, depth + 1);
            },
            .@"switch", .switch_comma => {
                for (tree.fullSwitch(node).?.ast.cases) |case| if (try e.carries(tree.fullSwitchCase(case).?.ast.target_expr, depth + 1)) return true; // unreachable: the tag is a switch's, its cases are cases
                return false;
            },
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                // A block with no label gives `void`.
                const brace = tree.nodeMainToken(node);
                if (brace < 2 or tree.tokenTag(brace - 1) != .colon or tree.tokenTag(brace - 2) != .identifier) return false;
                for (try c.facts.blockBreaks(c.file, node, tree.tokenSlice(brace - 2))) |value| if (try e.carries(value, depth + 1)) return true;
                return false;
            },
            .@"for", .for_simple, .@"while", .while_simple, .while_cont => {
                const start = tree.firstToken(node);
                const label: ?[]const u8 = if (start >= 2 and tree.tokenTag(start) != .identifier and tree.tokenTag(start - 1) == .colon and tree.tokenTag(start - 2) == .identifier) tree.tokenSlice(start - 2) else null;
                for (try c.facts.loopBreaks(c.file, node, label)) |value| if (try e.carries(value, depth + 1)) return true;
                const otherwise = if (tree.fullFor(node)) |loop| loop.ast.else_expr else tree.fullWhile(node).?.ast.else_expr; // unreachable: the tag is a loop's
                return if (otherwise.unwrap()) |value| e.carries(value, depth + 1) else false;
            },
            // A slice of a borrow borrows the same memory.
            .slice, .slice_open, .slice_sentinel => return e.carries(tree.fullSlice(node).?.ast.sliced, depth + 1), // unreachable: the tag is a slice's
            // An address of a part read through a borrow points into what it borrows.
            .address_of => {
                var place = tree.nodeData(node).node;
                while (true) place = switch (tree.nodeTag(place)) {
                    .field_access, .unwrap_optional, .grouped_expression => tree.nodeData(place).node_and_token[0],
                    .deref => tree.nodeData(place).node,
                    .array_access => tree.nodeData(place).node_and_node[0],
                    else => break,
                };
                return e.carries(place, depth + 1);
            },
            // A part of what carries a borrow carries it where the part may be a pointer, or a
            // value holding one; a number, a truth value or an enum's tag holds none.
            .field_access, .unwrap_optional, .deref, .array_access => {
                const whole = switch (tree.nodeTag(node)) {
                    .field_access, .unwrap_optional => tree.nodeData(node).node_and_token[0],
                    .deref => tree.nodeData(node).node,
                    else => tree.nodeData(node).node_and_node[0],
                };
                if (try plainValue(c, c.file, node, 0)) return false;
                if (scalarShaped(c, try c.facts.resolve(c.file, node))) return false;
                return e.carries(whole, depth + 1);
            },
            .identifier => {
                const index = Contract.local(c, node) orelse return false;
                const decl = model.declarations[@backingInt(index)];
                if ((try e.seen.getOrPut(c.allocator, index)).found_existing) return false;
                // A capture: of what the `if`, loop or `switch` reads.
                if (decl.kind == .capture) return if (c.facts.captureSource(c.file, decl.node)) |source| e.carries(source, depth + 1) else false;
                if (decl.kind != .variable) return false;
                const v = tree.fullVarDecl(decl.node) orelse return false;
                if (v.ast.init_node.unwrap()) |init| if (try e.carries(init, depth + 1)) return true;
                // Anything put in it later, whole or in a part (`r.v = s.expose()`).
                for (tree.nodes.items(.tag), 0..) |tag, i| {
                    if (tag != .assign) continue;
                    const sides = tree.nodeData(@fromBackingInt(@intCast(i))).node_and_node;
                    const root = placeRoot(tree, sides[0]) orelse continue;
                    if (Contract.local(c, root) != index) continue;
                    if (try e.carries(sides[1], depth + 1)) return true;
                }
                return false;
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return e.builtin(node, depth),
            else => {},
        }
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullStructInit(&buffer, node)) |literal| {
            for (literal.ast.fields) |field| if (try e.carries(field, depth + 1)) return true;
            return false;
        }
        if (tree.fullArrayInit(&buffer, node)) |literal| {
            for (literal.ast.elements) |element| if (try e.carries(element, depth + 1)) return true;
            return false;
        }
        if (try exposure(c, node)) return true;
        // A call given a borrow may return it, where what it returns may be a pointer.
        var call_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&call_buffer, node)) |call| {
            var given = false;
            if (tree.nodeTag(call.ast.fn_expr) == .field_access) given = try e.carries(tree.nodeData(call.ast.fn_expr).node_and_token[0], depth + 1);
            for (call.ast.params) |arg| given = given or try e.carries(arg, depth + 1);
            if (given and !scalarShaped(c, try c.facts.resolve(c.file, node))) e.unknown = e.unknown orelse node;
        }
        return false;
    }
    /// A builtin's value: what keeps its operand's address carries what the operand does.
    fn builtin(e: *Exposure, node: Ast.Node.Index, depth: usize) Context.Error!bool {
        const c = e.c;
        const tree = try c.project.syntax(try c.source());
        const name = tree.tokenSlice(tree.nodeMainToken(node));
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        const kept = [_][]const u8{ "@as", "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@addrSpaceCast", "@bitCast" };
        for (kept) |each| if (std.mem.eql(u8, name, each)) return args.len != 0 and try e.carries(args[args.len - 1], depth + 1);
        if (std.mem.eql(u8, name, "@field")) return args.len != 0 and try e.carries(args[0], depth + 1);
        if (std.mem.eql(u8, name, "@unionInit")) return args.len == 3 and try e.carries(args[2], depth + 1);
        // A number, a type, text, a truth value or nothing: no pointer.
        const none = [_][]const u8{ "@TypeOf", "@sizeOf", "@alignOf", "@bitSizeOf", "@offsetOf", "@bitOffsetOf", "@typeName", "@tagName", "@errorName", "@typeInfo", "@intFromPtr", "@intFromBool", "@intFromEnum", "@intFromError", "@intFromFloat", "@hasDecl", "@hasField", "@memcpy", "@memset", "@memmove", "@prefetch", "@compileError", "@panic", "@popCount", "@clz", "@ctz", "@byteSwap", "@bitReverse", "@truncate", "@intCast", "@floatCast", "@floatFromInt", "@divExact", "@divFloor", "@divTrunc", "@mod", "@rem", "@min", "@max", "@abs", "@sqrt", "@atomicStore" };
        for (none) |each| if (std.mem.eql(u8, name, each)) return false;
        // Any other builtin given a borrow gives a value this does not follow.
        for (args) |arg| if (try e.carries(arg, depth + 1)) {
            if (!scalarShaped(c, try c.facts.resolve(c.file, node))) e.unknown = e.unknown orelse node;
            return false;
        };
        return false;
    }
};

/// Whether a value is a number, a truth value, an enum's tag or nothing: no pointer in it.
fn scalarShaped(c: *Context, value: Facts.Value) bool {
    return switch (value) {
        .primitive => |name| !std.mem.eql(u8, name, "anyopaque"),
        .error_union => |inner| scalarShaped(c, inner.*),
        // An enum's tag, by the keyword its container is declared with (`Facts.kindOf`).
        .instance => |container| c.facts.kindOf(container) == .keyword_enum,
        else => false,
    };
}

/// Whether an owner of kind `k` may move by assignment: no erasure owed to the bytes left
/// behind (secrets), no address an owner or its borrowers keep (guarded values, a budget its
/// reservations point at, an owner bound to its address in Debug).
fn movable(k: Contract.Kind) bool {
    return switch (k) {
        .guard, .handoff, .shared, .reservation, .buffer, .slots, .table, .machine, .must_use, .stage, .issuer, .atomic, .context => true,
        else => false,
    };
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
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (candidate == source) continue;
        const ref = model.reference(candidate) orelse continue;
        if (ref.declaration != index) continue;
        var deferred = false;
        var parents = model.node_parents[i];
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
            if (placeRoot(tree, value) == null) {
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
    const model = &c.project.at(c.file).model;
    // The part of the local read: `r`, `r.a`, `r.a[0]`, `r.?`.
    var part = reference;
    while (model.parentOf(part)) |parent| {
        switch (tree.nodeTag(parent)) {
            .field_access, .unwrap_optional, .grouped_expression => if (tree.nodeData(parent).node_and_token[0] != part) break,
            .array_access => if (tree.nodeData(parent).node_and_node[0] != part) break,
            else => break,
        }
        part = parent;
    }
    const parent = model.parentOf(part) orelse return .copy;
    switch (tree.nodeTag(parent)) {
        .address_of => return .address,
        .assign => {
            const target = tree.nodeData(parent).node_and_node[0];
            // Written over, not read.
            if (target == part and part == reference) return .read;
            if (tree.nodeTag(target) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) return .read;
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(parent));
            if (std.mem.eql(u8, name, "@TypeOf") or std.mem.eql(u8, name, "@sizeOf") or std.mem.eql(u8, name, "@alignOf")) return .read;
        },
        else => {},
    }
    // A method called on it, or on a part: its receiver.
    if (tree.nodeTag(part) == .field_access) {
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, parent)) |call| if (call.ast.fn_expr == part) {
            return switch (try pointerReceiver(c, parent)) {
                .yes => .address,
                .no => .copy,
                .unknown => |why| .{ .unknown = why },
            };
        };
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

/// Whether a type expression is plain data: a primitive type (`usize`, `bool`, `type`), or an array,
/// slice, pointer, optional or error union of plain data. No aegis owner or capability is such a value.
fn plainType(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: usize) Context.Error!bool {
    if (depth == 64) return false;
    const tree = &c.project.at(file).file.tree;
    if (tree.fullPtrType(node)) |ptr| return plainType(c, file, ptr.ast.child_type, depth + 1);
    if (tree.fullArrayType(node)) |array| return plainType(c, file, array.ast.elem_type, depth + 1);
    return switch (tree.nodeTag(node)) {
        .optional_type => plainType(c, file, tree.nodeData(node).node, depth + 1),
        .error_union => plainType(c, file, tree.nodeData(node).node_and_node[1], depth + 1),
        .identifier => try c.facts.resolve(file, node) == .primitive,
        // A struct or tuple type written in place, every field plain: never a published aegis
        // type, which has a name.
        .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing => blk: {
            var buffer: [2]Ast.Node.Index = undefined;
            const decl = tree.fullContainerDecl(&buffer, node).?; // unreachable: the tag is a container's
            if (tree.tokenTag(decl.ast.main_token) != .keyword_struct) break :blk false;
            for (decl.ast.members) |member| {
                const field = c.project.at(file).model.containerField(tree, member) orelse continue;
                const t = field.ast.type_expr.unwrap() orelse break :blk false;
                if (!try plainType(c, file, t, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        // `@Vector(n, T)`: lanes of plain data.
        .builtin_call_two, .builtin_call_two_comma => blk: {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@Vector")) break :blk false;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            break :blk args.len == 2 and try plainType(c, file, args[1], depth + 1);
        },
        else => false,
    };
}

/// Whether a value is plain data by what is written where it comes from: a literal, a local or
/// parameter declared plain or initialized with plain data, an element or the address of plain data,
/// or the result of a function declared to return plain data.
fn plainValue(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: usize) Context.Error!bool {
    if (depth == 64) return false;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    switch (tree.nodeTag(node)) {
        // An enum's tag, an error, or a declaration literal naming a container's `const`
        // (`.empty`), known as the program compiles: no live owner.
        .number_literal, .char_literal, .string_literal, .multiline_string_literal, .enum_literal, .error_value => return true,
        // Zig has no operator overloading: an operator gives a number, a truth value, a vector or
        // (`+`, `-` on a pointer) a pointer, never a struct an owner is.
        .add, .add_wrap, .add_sat, .sub, .sub_wrap, .sub_sat, .mul, .mul_wrap, .mul_sat, .div, .mod, .shl, .shl_sat, .shr, .bit_and, .bit_or, .bit_xor, .bit_not, .negation, .negation_wrap, .bool_not, .bool_and, .bool_or, .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal => return true,
        .@"comptime", .@"try", .address_of => return plainValue(c, file, tree.nodeData(node).node, depth + 1),
        .grouped_expression => return plainValue(c, file, tree.nodeData(node).node_and_token[0], depth + 1),
        // Arrays joined: plain when what they are made of is.
        .array_cat => {
            const sides = tree.nodeData(node).node_and_node;
            return try plainValue(c, file, sides[0], depth + 1) and try plainValue(c, file, sides[1], depth + 1);
        },
        .array_access => return plainValue(c, file, tree.nodeData(node).node_and_node[0], depth + 1),
        // The payload of plain data is plain: Zig requires the other side to coerce to it.
        .@"orelse", .@"catch" => return plainValue(c, file, tree.nodeData(node).node_and_node[0], depth + 1),
        .@"if", .if_simple => {
            // Peer types: a struct has none with a number, a truth value or a pointer, so one
            // plain branch makes the whole plain (a branch that never ends gives nothing).
            const branch = tree.fullIf(node).?;
            const otherwise = branch.ast.else_expr.unwrap() orelse return false;
            return try plainValue(c, file, branch.ast.then_expr, depth + 1) or try plainValue(c, file, otherwise, depth + 1);
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            // `{}`: void.
            var buffer: [2]Ast.Node.Index = undefined;
            const brace = tree.nodeMainToken(node);
            if ((tree.blockStatements(&buffer, node) orelse return false).len == 0 and (brace < 2 or tree.tokenTag(brace - 1) != .colon)) return true;
            return plainBreaks(c, file, node, depth + 1);
        },
        // A literal of plain values, with no type of its own or of a plain type.
        .array_init_dot_two, .array_init_dot_two_comma, .array_init_dot, .array_init_dot_comma, .array_init_one, .array_init_one_comma, .array_init, .array_init_comma => {
            var buffer: [2]Ast.Node.Index = undefined;
            const literal = tree.fullArrayInit(&buffer, node).?; // unreachable: the tag is an array literal's
            if (literal.ast.type_expr.unwrap()) |t| return plainType(c, file, t, depth + 1);
            for (literal.ast.elements) |element| if (!try plainValue(c, file, element, depth + 1)) return false;
            return true;
        },
        .struct_init_dot_two, .struct_init_dot_two_comma, .struct_init_dot, .struct_init_dot_comma => {
            var buffer: [2]Ast.Node.Index = undefined;
            for (tree.fullStructInit(&buffer, node).?.ast.fields) |field| if (!try plainValue(c, file, field, depth + 1)) return false; // unreachable: the tag is a struct literal's
            return true;
        },
        .identifier => {
            const ref = model.reference(node) orelse return false;
            const index = ref.declaration orelse return false;
            const decl = model.declarations[@backingInt(index)];
            if (decl.kind == .parameter) return plainType(c, file, decl.node, depth + 1);
            // A `for` capture over plain inputs: an element of plain data, or a number.
            if (decl.kind == .capture) {
                const loop = tree.fullFor(decl.node) orelse return false;
                for (loop.ast.inputs) |input| {
                    if (tree.nodeTag(input) == .for_range) continue;
                    if (!try plainValue(c, file, input, depth + 1)) return false;
                }
                return true;
            }
            const v = tree.fullVarDecl(decl.node) orelse return false;
            if (v.ast.type_node.unwrap()) |t| return plainType(c, file, t, depth + 1);
            const init = v.ast.init_node.unwrap() orelse return false;
            return plainValue(c, file, init, depth + 1);
        },
        .call_one, .call_one_comma, .call, .call_comma => {
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

/// The place `std.mem.asBytes(&x)` names: `x`.
fn addressed(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (call.ast.params.len != 1 or tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]), "asBytes")) return null;
    const operand = call.ast.params[0];
    if (tree.nodeTag(operand) != .address_of) return null;
    return tree.nodeData(operand).node;
}

fn pointerShaped(value: Facts.Value) bool {
    return switch (value) {
        .pointer => true,
        .optional => |inner| inner.* == .pointer,
        else => false,
    };
}
fn ownedValue(c: *Context, node: Ast.Node.Index, depth: usize) Context.Error!bool {
    if (depth == 64) return false;
    const tree = try c.project.syntax(try c.source());
    const index = Contract.local(c, node) orelse return false;
    const decl = c.project.at(c.file).model.declarations[@backingInt(index)];
    if (decl.kind == .parameter) return tree.fullPtrType(decl.node) == null and try Contract.owner(c, decl.node) != null;
    const v = tree.fullVarDecl(decl.node) orelse return false;
    if (v.ast.type_node.unwrap()) |t| {
        if (tree.fullPtrType(t) != null) return false;
        if (tree.nodeTag(t) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(t)), "type")) return false;
        return try Contract.owner(c, t) != null;
    }
    var init = v.ast.init_node.unwrap() orelse return false;
    if (tree.nodeTag(init) == .identifier) return ownedValue(c, init, depth + 1);
    if (tree.nodeTag(init) == .@"try") init = tree.nodeData(init).node;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, init) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const name = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]));
    return std.mem.eql(u8, name, "init") or std.mem.eql(u8, name, "adopt") or std.mem.eql(u8, name, "acquire");
}

fn exposure(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const data = tree.nodeData(call.ast.fn_expr).node_and_token;
    const name = try Model.identifier(c.allocator, tree.tokenSlice(data[1]));
    if (!std.mem.eql(u8, name, "expose") and !std.mem.eql(u8, name, "exposeMut") and !std.mem.eql(u8, name, "value")) return false;
    const k = (try requiredOwner(c, data[0], copies, data[1])) orelse return false;
    return ((k == .secret or k == .bytes) and (std.mem.eql(u8, name, "expose") or std.mem.eql(u8, name, "exposeMut"))) or (k == .guard and std.mem.eql(u8, name, "value"));
}
fn checkCleanup(c: *Context) Context.Error!void {
    if (!try begin(c, cleanup)) return;
    const tree = try c.project.syntax(try c.source());
    const model = &c.project.at(c.file).model;
    for (0..tree.nodes.len) |i| try checkBinding(c, tree, @fromBackingInt(@intCast(i)), cleanup);
    for (model.declarations) |decl| {
        const k = (try acquiredOwner(c, tree, model, decl, true)) orelse continue;
        // A local's statements follow its declaration (a destructure's, the destructure); an
        // `if`'s payload's are its branch's.
        const scope = if (decl.kind == .capture) tree.fullIf(decl.node).?.ast.then_expr else model.scopes[@backingInt(decl.scope)].node; // unreachable: acquiredOwner takes only an `if`'s capture
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, scope) orelse {
            try c.undecided(cleanup, tree.tokenStart(decl.token), .unsupported, "an acquisition captured by a branch that is no block; no leak claimed");
            continue;
        };
        const declared = model.parentOf(decl.node);
        const at = if (decl.kind == .capture) 0 else for (statements, 0..) |stmt, i| {
            if (stmt == decl.node or (declared != null and stmt == declared.? and tree.nodeTag(stmt) == .assign_destructure)) break i + 1;
        } else continue;
        const flow: Flow = .{ .c = c, .tree = tree, .model = model, .token = decl.token, .kind = k, .scope = scope };
        switch (try flow.walk(statements[at..], .live)) {
            .paths => |paths| if (paths.falls == .live) try c.at(cleanup, decl.token, "recognized local acquisition reaches block end without cleanup; review ownership obligation"),
            .split, .uncertain => try c.undecided(cleanup, tree.tokenStart(decl.token), .unsupported, "cleanup/error exits/transfers/aliases require unsupported flow facts; no leak claimed"),
        }
    }
    for (0..tree.nodes.len) |i| try strayAcquisition(c, tree, model, @fromBackingInt(@intCast(i)));
}

/// An acquisition whose owner goes anywhere but where A003 follows it: a block's local it
/// initialises (followed above), a `return` (the caller's), or a store into memory (a field,
/// an element, a pointer's target: the holder's). Discarded (`_ = try dir.openFile(...)`) it
/// leaks; assigned to a local, put in a literal or a destructure, handed to a call or chosen by
/// a branch, it is not followed: undecided, never clear.
fn strayAcquisition(c: *Context, tree: *const Ast, model: *const Model, node: Ast.Node.Index) Context.Error!void {
    var call_buffer: [1]Ast.Node.Index = undefined;
    _ = tree.fullCall(&call_buffer, node) orelse return;
    // Up through what hands it on unchanged, the literals it is a field or element of and the
    // branches it is the value of: their place decides (`return .{ .o = o.move() }`,
    // `slot.* = .{ ... }`, `.w = if (w) |x| x.move() else null`).
    // `value` is the acquisition as handed on, `at` what its place is decided at.
    var at = node;
    var value = node;
    var in_literal = false;
    const parent = while (model.parentOf(at)) |up| : (at = up) {
        if (wraps(tree, up, at)) {
            if (!in_literal) value = up;
            continue;
        }
        if (literalPart(tree, up, at) or branchValue(tree, up, at)) {
            in_literal = true;
            continue;
        }
        break up;
    } else return;
    // A declaration's value: a block's local is followed from it, unless the owner is a part
    // of a literal it holds; any other declaration holds no owner made at run time.
    if (tree.fullVarDecl(parent) != null and !in_literal) return;
    // A local A003 follows from it, through the ways it is made (`acquiredOwner`): a branch's
    // value, a destructure's element of a literal, an `if`'s payload.
    if (try followedAt(c, tree, model, parent, at)) return;
    const discarded = switch (try Facts.accesses.useOf(c.facts, c.file, at)) {
        .returned => return,
        // A statement (a block's, a `defer`'s): Zig refuses to ignore a value that is not
        // `void`, so it gives none, an owner least of all.
        .statement => return,
        .discarded => true,
        .stored => |site| blk: {
            const target = site.target orelse break :blk false;
            switch (Facts.accesses.formOf(tree.nodeTag(target))) {
                .leaf => {
                    // A local A003 follows, acquired again (`held = b.acquire()`): its flow
                    // reads the assignment.
                    if (!in_literal) if (Contract.local(c, target)) |index| {
                        if (try acquiredOwner(c, tree, model, model.declarations[@backingInt(index)], false) != null) return;
                    };
                    break :blk false;
                },
                // Stored into memory, the owner is the holder's: memory reached through a
                // pointer or a container's variable. A block's local holding it in a field or
                // an element (`box.g = l.acquire()`) is not followed, nor is memory that does
                // not resolve: undecided.
                else => switch (try Facts.accesses.storedIn(c.facts, c.file, target)) {
                    .through => return,
                    .declaration => |held| {
                        const model_of = &c.project.at(held.file).model;
                        switch (model_of.scopes[@backingInt(model_of.declarations[@backingInt(held.index)].scope)].kind) {
                            .file, .container => return,
                            else => break :blk false,
                        }
                    },
                    .unresolved => break :blk false,
                },
            }
        },
        else => false,
    };
    _ = (try acquisitionKind(c, tree, value, true)) orelse return;
    if (discarded) return c.at(cleanup, tree.nodeMainToken(node), "an acquisition discarded with `_ =` is never released");
    try c.undecided(cleanup, tree.tokenStart(tree.nodeMainToken(node)), .unsupported, "an acquisition whose owner is not a block's local, returned, or stored into memory is not followed; no leak claimed");
}

/// Whether the place `parent` gives what `at` holds is a local A003 follows: a declaration's,
/// a destructure's element, or an `if`'s or `while`'s payload of its condition.
fn followedAt(c: *Context, tree: *const Ast, model: *const Model, parent: Ast.Node.Index, at: Ast.Node.Index) Context.Error!bool {
    var nodes: std.ArrayList(Ast.Node.Index) = .empty;
    var payload: ?Ast.TokenIndex = null;
    if (tree.fullVarDecl(parent) != null) {
        try nodes.append(c.allocator, parent);
    } else if (tree.nodeTag(parent) == .assign_destructure) {
        const destructure = tree.assignDestructure(parent);
        if (destructure.ast.value_expr != at) return false;
        try nodes.appendSlice(c.allocator, destructure.ast.variables);
    } else if (tree.fullIf(parent)) |branch| {
        if (branch.ast.cond_expr != at) return false;
        payload = branch.payload_token;
    } else if (tree.fullWhile(parent)) |loop| {
        if (loop.ast.cond_expr != at) return false;
        payload = loop.payload_token;
    } else return false;
    for (model.declarations) |decl| {
        const mine = if (payload) |token| decl.kind == .capture and decl.token == token else std.mem.findScalar(Ast.Node.Index, nodes.items, decl.node) != null;
        if (mine and try acquiredOwner(c, tree, model, decl, false) != null) return true;
    }
    return false;
}

/// Whether `node` is a value the expression `parent` may give: an `if`'s branch, a switch
/// prong's, `catch`'s or `orelse`'s right side.
fn branchValue(tree: *const Ast, parent: Ast.Node.Index, node: Ast.Node.Index) bool {
    if (tree.fullIf(parent)) |branch| return branch.ast.then_expr == node or branch.ast.else_expr.unwrap() == node;
    if (tree.fullSwitchCase(parent)) |prong| return prong.ast.target_expr == node;
    if (tree.fullSwitch(parent) != null) return tree.nodeTag(node) == .switch_case or tree.nodeTag(node) == .switch_case_one or tree.nodeTag(node) == .switch_case_inline or tree.nodeTag(node) == .switch_case_inline_one;
    return switch (tree.nodeTag(parent)) {
        .@"catch", .@"orelse" => tree.nodeData(parent).node_and_node[1] == node,
        else => false,
    };
}

/// Whether `node` is a field's value or an element of the literal `parent`.
fn literalPart(tree: *const Ast, parent: Ast.Node.Index, node: Ast.Node.Index) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, parent)) |literal| return std.mem.findScalar(Ast.Node.Index, literal.ast.fields, node) != null;
    if (tree.fullArrayInit(&buffer, parent)) |literal| return std.mem.findScalar(Ast.Node.Index, literal.ast.elements, node) != null;
    return false;
}

/// Whether `parent` hands its operand `node` on unchanged: `try`, `catch`'s or `orelse`'s
/// left side, a grouping, or `@as`'s value.
fn wraps(tree: *const Ast, parent: Ast.Node.Index, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(parent)) {
        .@"try" => true,
        .grouped_expression => tree.nodeData(parent).node_and_token[0] == node,
        .@"catch", .@"orelse" => tree.nodeData(parent).node_and_node[0] == node,
        .builtin_call_two, .builtin_call_two_comma => blk: {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parent)), "@as")) break :blk false;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, parent, &buffer);
            break :blk args.len == 2 and args[1] == node;
        },
        else => false,
    };
}

/// The kind of owner A003 follows the local `decl` as, from its acquisition to block end: a
/// block's local initialised by an actual acquisition expression, never an owner alias or type
/// alias (an owner's constructor, a guard's acquisition, or a function of the program's own that
/// returns an owner), of a kind with a release. One that fails holds nothing: `try` and `catch`
/// leave the acquisition itself. `report`: whether a receiver that does not resolve is reported
/// undecided, as A003's own.
fn acquiredOwner(c: *Context, tree: *const Ast, model: *const Model, decl: Model.Declaration, report: bool) Context.Error!?Contract.Kind {
    const init = acquiredFrom(tree, model, decl) orelse return null;
    var leaves: std.ArrayList(Ast.Node.Index) = .empty;
    try valueLeaves(c, tree, model, init, &leaves, 0);
    // Every way the value is made acquires the same kind of owner, or none does: one where
    // only some do, or kinds differ, may or may not be an owner.
    var kind: ?Contract.Kind = null;
    var plain = false;
    for (leaves.items) |leaf| {
        const k = (try acquisitionOwner(c, tree, leaf, report)) orelse {
            plain = true;
            continue;
        };
        if (kind != null and kind.? != k) plain = true;
        kind = k;
    }
    const k = kind orelse return null;
    if (plain) {
        if (report) try c.undecided(cleanup, tree.tokenStart(decl.token), .unsupported, "a local made by an acquisition on some of the ways it is made only; no leak claimed");
        return null;
    }
    return k;
}

/// What a local `decl` holds from its start: a variable's value, a destructure's element of a
/// literal of as many, an `if`'s payload its condition's. A `while`'s or `for`'s capture, or a
/// destructure of anything else, is none.
fn acquiredFrom(tree: *const Ast, model: *const Model, decl: Model.Declaration) ?Ast.Node.Index {
    switch (decl.kind) {
        .variable => if (model.scopes[@backingInt(decl.scope)].kind != .block) return null,
        .capture => {
            const branch = tree.fullIf(decl.node) orelse return null;
            if (branch.payload_token == null or branch.error_token == decl.token) return null;
            return branch.ast.cond_expr;
        },
        else => return null,
    }
    const v = tree.fullVarDecl(decl.node) orelse return null;
    if (v.ast.init_node.unwrap()) |init| return init;
    const parent = model.parentOf(decl.node) orelse return null;
    if (tree.nodeTag(parent) != .assign_destructure) return null;
    const destructure = tree.assignDestructure(parent);
    const position = std.mem.findScalar(Ast.Node.Index, destructure.ast.variables, decl.node) orelse return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const literal = tree.fullArrayInit(&buffer, destructure.ast.value_expr) orelse return null;
    if (literal.ast.elements.len != destructure.ast.variables.len) return null;
    return literal.ast.elements[position];
}

/// The expressions whose value `node`'s is, through what hands one on whole: `try`, parentheses,
/// `@as`, both sides of `catch` and `orelse`, an `if`'s or a switch prong's result, a labeled
/// block's `break`s. One that gives no value (`return`, `unreachable`, a jump, an unlabeled
/// block) is none.
fn valueLeaves(c: *Context, tree: *const Ast, model: *const Model, node: Ast.Node.Index, into: *std.ArrayList(Ast.Node.Index), depth: u8) Context.Error!void {
    if (depth == 16) return into.append(c.allocator, node);
    const next = depth + 1;
    switch (tree.nodeTag(node)) {
        .@"try" => return valueLeaves(c, tree, model, tree.nodeData(node).node, into, next),
        .grouped_expression => return valueLeaves(c, tree, model, tree.nodeData(node).node_and_token[0], into, next),
        .@"catch", .@"orelse" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            try valueLeaves(c, tree, model, lhs, into, next);
            return valueLeaves(c, tree, model, rhs, into, next);
        },
        .@"return", .unreachable_literal, .@"break", .@"continue" => return,
        .builtin_call_two, .builtin_call_two_comma => {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len == 2 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@as")) return valueLeaves(c, tree, model, args[1], into, next);
        },
        .@"switch", .switch_comma => {
            for (tree.fullSwitch(node).?.ast.cases) |case| try valueLeaves(c, tree, model, tree.fullSwitchCase(case).?.ast.target_expr, into, next);
            return;
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            const lbrace = tree.nodeMainToken(node);
            if (lbrace >= 2 and tree.tokenTag(lbrace - 1) == .colon) {
                const label = tree.tokenSlice(lbrace - 2);
                for (tree.nodes.items(.tag), 0..) |tag, i| {
                    if (tag != .@"break") continue;
                    const jump: Ast.Node.Index = @fromBackingInt(@intCast(i));
                    const at = tree.nodeMainToken(jump);
                    if (at < tree.firstToken(node) or at > tree.lastToken(node)) continue;
                    const target, const value = tree.nodeData(jump).opt_token_and_opt_node;
                    if (!std.mem.eql(u8, tree.tokenSlice(target.unwrap() orelse continue), label)) continue;
                    try valueLeaves(c, tree, model, value.unwrap() orelse continue, into, next);
                }
            }
            // An unlabeled block gives no value: one a handler runs leaves (`catch { ...;
            // return error.Busy; }`).
            return;
        },
        else => if (tree.fullIf(node)) |branch| if (branch.ast.else_expr.unwrap()) |otherwise| {
            try valueLeaves(c, tree, model, branch.ast.then_expr, into, next);
            return valueLeaves(c, tree, model, otherwise, into, next);
        },
    }
    try into.append(c.allocator, node);
}

/// The owner a call at `acquisition` gives: a std handle opened raw, an owner's constructor or
/// an operation that gives one by its name, or the program's function returning one.
fn acquisitionOwner(c: *Context, tree: *const Ast, acquisition: Ast.Node.Index, report: bool) Context.Error!?Contract.Kind {
    var call_buffer: [1]Ast.Node.Index = undefined;
    const acquired = tree.fullCall(&call_buffer, acquisition) orelse return null;
    // By a function of the generic's type parameter: each binding's, checked at the binding.
    if (c.facts.madeByParameter(c.file, acquisition) != null) return null;
    // A std handle acquired raw (`dir.openFile`): released by its `close`.
    if (try Shapes.acquiresHandle(c, cleanup, acquisition)) return .std_handle;
    const named = tree.nodeTag(acquired.ast.fn_expr) == .field_access and named: {
        const operation = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(acquired.ast.fn_expr).node_and_token[1]));
        break :named std.mem.eql(u8, operation, "init") or std.mem.eql(u8, operation, "adopt") or Contract.acquisition(operation);
    };
    // One that may give an owner is read by its type below, undecided where that does not resolve.
    if (!named and try givesOwner(c, acquisition) == .no) return null;
    if (try unlisted(c, acquisition)) return null;
    const k = if (report)
        (try requiredOwner(c, acquisition, cleanup, tree.nodeMainToken(acquired.ast.fn_expr))) orelse return null
    else switch (try ownerKind(c, acquisition, cleanup)) {
        .owner => |k| k,
        .other, .unknown => return null,
    };
    if (releases(k) == null) return null;
    return k;
}

/// The kind of owner the expression `init` acquires, read through `try`, `catch`, `orelse`, a
/// grouping and `@as` to the acquisition itself (`acquisitionOwner`), or null where it acquires
/// none.
fn acquisitionKind(c: *Context, tree: *const Ast, init: Ast.Node.Index, report: bool) Context.Error!?Contract.Kind {
    var acquisition = init;
    while (true) acquisition = switch (tree.nodeTag(acquisition)) {
        .@"try" => tree.nodeData(acquisition).node,
        .grouped_expression => tree.nodeData(acquisition).node_and_token[0],
        .@"catch", .@"orelse" => tree.nodeData(acquisition).node_and_node[0],
        .builtin_call_two, .builtin_call_two_comma => blk: {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(acquisition)), "@as")) break;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, acquisition, &buffer);
            if (args.len != 2) break;
            break :blk args[1];
        },
        else => break,
    };
    return acquisitionOwner(c, tree, acquisition, report);
}

/// Whether A003 follows the local `decl` from its acquisition (`acquiredOwner`) on this file,
/// where it runs: a use of it after its cleanup is then A003's to report or leave undecided, and
/// A019 leaves it there. Anything short of that, a limit or a receiver that does not resolve
/// among it, leaves the local A019's.
fn followsCleanup(c: *Context, decl: Model.Declaration) Context.Error!bool {
    if (!c.config.has(cleanup)) return false;
    if (try c.inLibrary(Contract.library, c.file)) return false;
    const tree = try c.project.syntax(try c.source());
    return try acquiredOwner(c, tree, &c.project.at(c.file).model, decl, false) != null;
}

/// Whether the local declared at `site` is initialised by an acquisition: an owner's
/// constructor or an operation that gives one by its name.
fn acquiring(c: *Context, site: Facts.Key) Context.Error!bool {
    const tree = &c.project.at(site.file).file.tree;
    const v = tree.fullVarDecl(site.node) orelse return false;
    const init = v.ast.init_node.unwrap() orelse return false;
    const value = switch (tree.nodeTag(init)) {
        .@"try" => tree.nodeData(init).node,
        .@"catch" => tree.nodeData(init).node_and_node[0],
        else => init,
    };
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, value) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const operation = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]));
    return std.mem.eql(u8, operation, "init") or std.mem.eql(u8, operation, "adopt") or Contract.acquisition(operation);
}

/// Whether `call` gives a value of a type the library declares and the contract does not list,
/// a guard and its `Handoff` aside: the contract names every type that carries an obligation,
/// so such a result owes no release here.
fn unlisted(c: *Context, call: Ast.Node.Index) Context.Error!bool {
    if (try Contract.owner(c, call) != null) return false;
    const value = switch (try c.facts.resolve(c.file, call)) {
        .error_union => |payload| payload.*,
        else => |value| value,
    };
    const container = switch (value) {
        .instance => |container| container,
        else => return false,
    };
    if (try c.role(Contract.library, value) != null) return false;
    if (try typed(c, value, 0) == .owner) return false;
    return c.inLibrary(Contract.library, container.file);
}

/// Whether `call` gives an owner itself, not a pointer to one: an operation of a published type
/// whose result is a new owner by value (a budget's reservation, a shared value's handle, an
/// opened scope), or a function of the program's own that returns one held, the caller's to
/// release (Flow's `return`). By its result's type, whatever it calls: unknown where that does
/// not resolve.
fn givesOwner(c: *Context, call: Ast.Node.Index) Context.Error!Is {
    var resolved = try c.facts.resolve(c.file, call);
    // A call whose value does not resolve where the function it calls does (a decl literal's,
    // `.of(gpa, n)`): what that function declares it returns.
    if (resolved == .unknown) switch (try calledFunction(c, c.file, call)) {
        .function => |function| {
            // A result written as a pointer (`*T`, `[]T`, through `!` and `?`) borrows: no owner.
            if (try pointerResult(c, function)) return .no;
            resolved = try c.facts.callResult(.{ .function = function }, {});
        },
        .unknown => {},
    };
    return switch (heldInstance(resolved)) {
        .yes => .yes,
        .no => .no,
        .unknown => |why| if (try stdTyped(c, call)) .no else .{ .unknown = why },
    };
}

/// Whether a value holds an instance by value, an owner it may be: through an error union, an
/// optional and an array (`?Guard`, `[2]Guard`), or as any of a choice of types (`if (shared)
/// ReadGuard else WriteGuard`).
fn heldInstance(value: Facts.Value) Is {
    return switch (value) {
        .instance => .yes,
        .error_union, .optional, .array => |inner| heldInstance(inner.*),
        .alternatives => |each| {
            var out: Is = .no;
            for (each) |one| switch (heldInstance(one)) {
                .yes => return .yes,
                .unknown => |why| out = .{ .unknown = why },
                .no => {},
            };
            return out;
        },
        .unknown => |why| .{ .unknown = why },
        else => .no,
    };
}

/// Whether `function` declares its result a pointer or a slice, through an error union and an
/// optional.
fn pointerResult(c: *Context, function: Facts.Decl) Context.Error!bool {
    const source = c.project.at(function.file);
    const tree = &source.file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, source.model.declarations[@backingInt(function.index)].node) orelse return false;
    // What the written result resolves to (`Facts.resolve`), never its form.
    var value = try c.facts.resolve(function.file, proto.ast.return_type.unwrap() orelse return false);
    while (true) value = switch (value) {
        .error_union, .optional => |inner| inner.*,
        else => return value == .pointer,
    };
}

/// Whether the call at `call` gives a value of one of std's types, which declare no aegis owner:
/// a function of std's whose result is one type at every call (`fixedType`), or a decl literal
/// (`.limited(n)`), of the type its place gives it, passed where such a function's parameter
/// is.
fn stdTyped(c: *Context, call: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    switch (try calledFunction(c, c.file, call)) {
        .function => |function| if (try c.facts.standard(function.file)) {
            const source = c.project.at(function.file);
            var buffer: [1]Ast.Node.Index = undefined;
            const proto = source.file.tree.fullFnProto(&buffer, source.model.declarations[@backingInt(function.index)].node) orelse return false;
            return fixedType(c, function.file, proto.ast.return_type.unwrap() orelse return false);
        },
        .unknown => {},
    }
    var call_buffer: [1]Ast.Node.Index = undefined;
    if (tree.nodeTag((tree.fullCall(&call_buffer, call) orelse return false).ast.fn_expr) != .enum_literal) return false;
    const parent = c.project.at(c.file).model.parentOf(call) orelse return false;
    const outer = (try Facts.calls.at(c.facts, c.file, parent)) orelse return false;
    const position = std.mem.findScalar(Ast.Node.Index, switch (outer.args) {
        .known => |known| known,
        .unknown => return false,
    }, call) orelse return false;
    const function = switch (try calledFunction(c, c.file, parent)) {
        .function => |function| function,
        .unknown => return false,
    };
    if (!try c.facts.standard(function.file)) return false;
    const source = c.project.at(function.file);
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = source.file.tree.fullFnProto(&buffer, source.model.declarations[@backingInt(function.index)].node) orelse return false;
    var it = proto.iterate(&source.file.tree);
    var at: usize = 0;
    while (it.next()) |param| : (at += 1) if (at == position) return fixedType(c, function.file, param.type_expr orelse return false);
    return false;
}

/// Whether the type written at `node` in `file` is one type wherever it is read: it names no
/// parameter, a function's or a type function's around it, no declaration a function's body
/// makes (a generic's `Self`), and no builtin (`@TypeOf(x)`).
fn fixedType(c: *Context, file: Project.FileId, node: Ast.Node.Index) bool {
    const source = c.project.at(file);
    const tree = &source.file.tree;
    var token = tree.firstToken(node);
    while (token <= tree.lastToken(node)) : (token += 1) switch (tree.tokenTag(token)) {
        .builtin => return false,
        .identifier => {
            // A member's name is its holder's to give.
            if (token > 0 and tree.tokenTag(token - 1) == .period) continue;
            const name = tree.tokenSlice(token);
            if (Model.primitive(name)) continue;
            const found = source.model.lookup(source.model.scopeOf(token), name, token) orelse return false;
            const record = source.model.declarations[@backingInt(found)];
            if (record.kind == .parameter) return false;
            var scope: ?Model.Scope.Id = record.scope;
            while (scope) |id| : (scope = source.model.scopes[@backingInt(id)].parent) {
                if (source.model.scopes[@backingInt(id)].kind == .function) return false;
            }
        },
        else => {},
    };
    return true;
}

/// The paths of a block after a local acquisition, statement by statement. The owner is live
/// until a direct `deinit` releases it, a `defer` schedules one, a guard's `handOff` gives its
/// release to the code the hand-off is passed to (a declared transfer), a `return` gives the
/// owner itself to the caller, or an assignment stores it where the function does not hold it
/// (`stored`), a call outside the program takes it by value (`argument`), or a statement takes
/// it by its `move` or by its address (`takes`). An `if` and a
/// `switch` are followed into their branches, a block into its statements and a loop
/// into its body, and branches that end apart go on apart while a flag tells them so (`Split`):
/// the body must leave the owner at its back edge as it found it, and the loop goes on in the
/// state its exits (its `break`s, and its condition when it can fail) agree on; a loop that
/// never exits ends the path. A release a branch or a body defers runs as it ends. Undecided:
/// an exit (`return`, `try`, a `break` or `continue` that leaves the walk) while live, paths
/// that meet in different states, a jump to a loop or block of the walk other than the loop it
/// is in, any use of the owner but its members or a loan (its address, a copy, an argument: a
/// transfer or an alias), a release nested where the walk does not follow. Findings: a second
/// direct cleanup, a member of the owner used after its release or transfer (a result
/// obligation's `deinit`, its check, aside), the owner's address discarded after release, an
/// `errdefer` that releases it again on an error exit after that.
const Flow = struct {
    c: *Context,
    tree: *const Ast,
    model: *const Model,
    token: Ast.TokenIndex,
    /// The owner's kind, which names its release.
    kind: Contract.Kind,
    /// The block the owner is declared in.
    scope: Ast.Node.Index,
    /// The innermost loop the walk is in, whose `break`s and `continue`s it follows.
    loop: ?Ast.Node.Index = null,
    /// Whether an `errdefer` releases the owner: an error leaving the walk does not leak it.
    errdeferred: bool = false,
    /// Whether the owner has moved into a local aggregate, which `token` now names: its
    /// obligation is the aggregate's, discharged only by giving the aggregate to the caller,
    /// as glint does not read the aggregate's own release.
    aggregate: bool = false,
    /// The value a flag that tells the owner's paths apart has on the paths this walk follows
    /// (`Split`): an `if` on it takes only the branch that value chooses. In a function walked
    /// for a call (`consumed`), a `comptime` parameter the call binds to a literal.
    known: ?Known = null,
    /// How many calls deep the walk reads a function a call gives the owner to (`consumed`).
    depth: u8 = 0,
    /// Whether `token` names a pointer to the owner (a parameter `consumed` walks): storing,
    /// passing or returning it aliases the owner, never moves it.
    pointer: bool = false,
    /// In a function walked for a call (`consumed`): the states its error exits leave the
    /// owner in, which say whether the call takes it whatever comes of it or only when it
    /// returns.
    exits: ?*Exits = null,

    /// `passed`: given by value as a call's argument (`try map.put(gpa, key, owner)`), moved
    /// into the call where nothing names the owner after it; where something does, the callee
    /// may have kept it or read a copy, and the walk stops undecided.
    const State = enum { live, released, deferred, passed };
    const States = std.EnumSet(State);
    /// The ways on from a run of statements, by the state each leaves the owner in: past its
    /// end, out of the walk's loop, and back to that loop's start. None: every path ends (a
    /// return, or a way out of the walk while the owner is released or its release deferred).
    const Paths = struct {
        falls: ?State = null,
        breaks: States = .empty,
        continues: States = .empty,
    };
    /// Paths past an `if` whose branches leave the owner in different states, told apart by a
    /// local flag the branches set to different values (`correlated`): the walk goes on from
    /// each state with the flag's value it comes with, and the paths meet again where they agree.
    const Split = struct {
        /// The ways out of the `if` itself; its end is in `when`.
        paths: Paths,
        /// The flag's declaration.
        flag: Model.Declaration.Id,
        /// The state past the `if` while the flag is false, and while it is true.
        when: [2]State,
    };
    const Known = struct { flag: Model.Declaration.Id, value: bool };
    /// Whether some error exit of a function walked for a call leaves the owner held, and
    /// whether some releases it (an `errdefer` that does counts).
    const Exits = struct { held: bool = false, released: bool = false };
    /// How a call given the owner's address takes it (`consumed`): on every path, or only
    /// where it returns, its error exits leaving the owner with the caller.
    const Taking = enum { always, on_success };
    const Outcome = union(enum) {
        paths: Paths,
        split: Split,
        uncertain,

        /// The paths, where they do not stay split.
        fn settled(outcome: Outcome) ?Paths {
            return switch (outcome) {
                .paths => |paths| paths,
                .split, .uncertain => null,
            };
        }
    };
    const ends: Outcome = .{ .paths = .{} };

    fn walk(flow: Flow, statements: []const Ast.Node.Index, start: State) Context.Error!Outcome {
        var f = flow;
        var state = start;
        var out: Paths = .{};
        for (statements, 0..) |stmt, at| {
            if (state == .passed) {
                switch (try f.reacquired(stmt)) {
                    .yes => {
                        state = .live;
                        continue;
                    },
                    .no => {},
                    .unknown => return .uncertain,
                }
                if (try f.uses(stmt) != .none) return .uncertain;
            }
            if (state == .live and !f.aggregate and !f.pointer) if (try f.movedInto(stmt)) |aggregate| {
                f.token = aggregate;
                f.aggregate = true;
                continue;
            };
            if (state == .live and !f.aggregate and !f.pointer) if (f.copiedInto(stmt)) |copy| {
                f.token = copy;
                continue;
            };
            // `errdefer owner.deinit()`: the owner is released on the error exits that follow.
            if (f.tree.nodeTag(stmt) == .@"errdefer" and state == .live and !f.aggregate and try f.releasesIn(f.tree.nodeData(stmt).node)) {
                f.errdeferred = true;
                continue;
            }
            if (try f.handedOff(stmt)) {
                if (state != .live) try f.c.at(cleanup, f.tree.nodeMainToken(stmt), "same local capability is handed off after its cleanup or transfer on this straight-line path");
                // Returned, the path ends there.
                if (f.tree.nodeTag(stmt) == .@"return") return .{ .paths = out };
                state = .released;
                continue;
            }
            if (state == .live and !f.aggregate and !f.pointer and try f.argument(stmt)) {
                // Its error exits leave the owner with the caller: the call failed to take it.
                const paths = (try f.jumps(stmt, state)).settled() orelse return .uncertain;
                out.breaks.setUnion(paths.breaks);
                out.continues.setUnion(paths.continues);
                if (paths.falls == null) return .{ .paths = out };
                state = .passed;
                continue;
            }
            if (state == .live and !f.aggregate) if (try f.takes(stmt)) |outcome| {
                const paths = outcome.settled() orelse return .uncertain;
                out.breaks.setUnion(paths.breaks);
                out.continues.setUnion(paths.continues);
                if (paths.falls == null) return .{ .paths = out };
                state = .released;
                continue;
            };
            if (!f.aggregate and !f.pointer and try f.stored(stmt)) {
                if (state != .live) try f.c.at(cleanup, f.tree.nodeMainToken(stmt), "same local owner is stored after its cleanup or transfer on this straight-line path");
                // A std handle is a value: the store copies it, and either copy may close the
                // one handle after (`job.file = fresh; ... fresh.close(io)`), so the local is
                // held beside the store, as a call given it holds it.
                state = if (f.kind == .std_handle) .passed else .released;
                continue;
            }
            const tag = f.tree.nodeTag(stmt);
            const deferred = !f.aggregate and tag == .@"defer" and try f.releasesIn(f.tree.nodeData(stmt).node);
            if (deferred or (!f.aggregate and try release(f.c, stmt, f.token, f.kind))) {
                if (state != .live) try f.c.at(cleanup, f.tree.nodeMainToken(stmt), if (deferred) "same local capability has repeated cleanup scheduled on this straight-line path" else "same local capability is cleaned twice on this straight-line path");
                state = if (deferred) .deferred else .released;
                continue;
            }
            // A discard of the owner's address has no retaining call or mutation.
            if (f.discardedAddress(stmt)) {
                if (state == .released) try f.c.at(cleanup, f.tree.nodeMainToken(f.tree.nodeData(f.tree.nodeData(stmt).node_and_node[1]).node), "same local owner used after cleanup on this straight-line path");
                continue;
            }
            // After the discharge, the check that it came is no use of the owner.
            if (state == .released and try f.tornDown(stmt)) continue;
            if (state == .released) switch (try f.reacquired(stmt)) {
                .yes => {
                    state = .live;
                    continue;
                },
                .no => {},
                .unknown => return .uncertain,
            };
            const next = switch (try f.step(stmt, state)) {
                .paths => |paths| paths,
                .split => |split| return f.apart(split, statements[at + 1 ..], out),
                .uncertain => return .uncertain,
            };
            out.breaks.setUnion(next.breaks);
            out.continues.setUnion(next.continues);
            state = next.falls orelse return .{ .paths = out };
        }
        out.falls = state;
        return .{ .paths = out };
    }

    /// The statements after a split, walked from each of its states with the flag's value it
    /// comes with; still split where they end apart. One flag at a time.
    fn apart(f: Flow, split: Split, rest: []const Ast.Node.Index, before: Paths) Context.Error!Outcome {
        if (f.known != null) return .uncertain;
        var out = before;
        out.breaks.setUnion(split.paths.breaks);
        out.continues.setUnion(split.paths.continues);
        var falls: [2]?State = @splat(null);
        for (0..2) |value| {
            var each = f;
            each.known = .{ .flag = split.flag, .value = value == 1 };
            const paths = (try each.walk(rest, split.when[value])).settled() orelse return .uncertain;
            out.breaks.setUnion(paths.breaks);
            out.continues.setUnion(paths.continues);
            falls[value] = paths.falls;
        }
        out.falls = meet(falls[0], falls[1]) catch return .{ .split = .{ .paths = out, .flag = split.flag, .when = .{ falls[0].?, falls[1].? } } };
        return .{ .paths = out };
    }

    /// A statement that neither releases nor acquires the owner again, from `state`.
    fn step(f: Flow, stmt: Ast.Node.Index, state: State) Context.Error!Outcome {
        switch (f.tree.nodeTag(stmt)) {
            .@"return" => if (state == .live and !f.pointer) if (f.tree.nodeData(stmt).opt_node.unwrap()) |value| {
                // The owner itself, returned held, or carried by value in what is returned (a
                // field of a returned literal, an argument of the call that makes it): its
                // release is the caller's.
                if (f.mine(value)) return ends;
                switch (try f.carried(value)) {
                    .yes => return ends,
                    .unknown => return .uncertain,
                    .no => {},
                }
            },
            .unreachable_literal => return ends,
            else => {},
        }
        // `_ = owner` discards it: no release, no transfer, so the owner goes on as it was.
        if (try Facts.accesses.discardedBy(f.c.facts, f.c.file, stmt)) |value| if (f.mine(value)) return .{ .paths = .{ .falls = state } };
        // `x = a catch |e| handler` and `const x = a orelse handler`: the handler is a branch
        // taken when `a` fails, the statement goes on in the state `a` leaves otherwise.
        if (f.handled(stmt)) |parts| {
            var out = (try f.leave(parts[0], state)).settled() orelse return .uncertain;
            const handler = (try f.block(parts[1], state)).settled() orelse return .uncertain;
            out.falls = meet(out.falls, handler.falls) catch return .uncertain;
            out.breaks.setUnion(handler.breaks);
            out.continues.setUnion(handler.continues);
            return .{ .paths = out };
        }
        if (f.tree.fullIf(stmt)) |branch| {
            // On the flag the walk knows: the branch its value takes.
            if (branch.payload_token == null and branch.error_token == null) if (f.decided(branch.ast.cond_expr)) |taken| {
                const node = if (taken) branch.ast.then_expr else branch.ast.else_expr.unwrap() orelse return .{ .paths = .{ .falls = state } };
                return f.block(node, state);
            };
            var out = (try f.leave(branch.ast.cond_expr, state)).settled() orelse return .uncertain;
            const then_paths = (try f.block(branch.ast.then_expr, state)).settled() orelse return .uncertain;
            const else_paths: Paths = if (branch.ast.else_expr.unwrap()) |other| (try f.block(other, state)).settled() orelse return .uncertain else .{ .falls = state };
            for ([_]Paths{ then_paths, else_paths }) |paths| {
                out.breaks.setUnion(paths.breaks);
                out.continues.setUnion(paths.continues);
            }
            out.falls = meet(then_paths.falls, else_paths.falls) catch {
                const flag = (try f.correlated(stmt, branch)) orelse return .uncertain;
                // Both fall, as only states that are there differ.
                const when: [2]State = if (flag.then) .{ else_paths.falls.?, then_paths.falls.? } else .{ then_paths.falls.?, else_paths.falls.? };
                return .{ .split = .{ .paths = out, .flag = flag.declaration, .when = when } };
            };
            return .{ .paths = out };
        }
        if (f.tree.fullWhile(stmt) != null or f.tree.fullFor(stmt) != null) return f.repeat(stmt, state);
        // An unlabeled `switch`: each prong a branch (its items are compile-time values).
        if (f.tree.fullSwitch(stmt)) |choice| if (choice.label_token == null) {
            var out = (try f.leave(choice.ast.condition, state)).settled() orelse return .uncertain;
            var falls: ?State = null;
            for (choice.ast.cases) |node| {
                const prong = f.tree.fullSwitchCase(node).?; // unreachable: a switch's cases are cases
                const paths = (try f.block(prong.ast.target_expr, state)).settled() orelse return .uncertain;
                falls = meet(falls, paths.falls) catch return .uncertain;
                out.breaks.setUnion(paths.breaks);
                out.continues.setUnion(paths.continues);
            }
            out.falls = falls;
            return .{ .paths = out };
        };
        // A block of its own, unlabeled: its statements in turn.
        switch (f.tree.nodeTag(stmt)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => if (f.tree.tokenTag(f.tree.nodeMainToken(stmt) -| 1) != .colon) return f.block(stmt, state),
            else => {},
        }
        return f.leave(stmt, state);
    }

    /// The value of a condition that is the flag the walk knows, or its negation.
    fn decided(f: Flow, cond: Ast.Node.Index) ?bool {
        const known = f.known orelse return null;
        var node = cond;
        var negated = false;
        while (true) switch (f.tree.nodeTag(node)) {
            .grouped_expression => node = f.tree.nodeData(node).node_and_token[0],
            .bool_not => {
                node = f.tree.nodeData(node).node;
                negated = !negated;
            },
            else => break,
        };
        if (f.tree.nodeTag(node) != .identifier) return null;
        const ref = f.model.reference(node) orelse return null;
        if (ref.declaration != known.flag) return null;
        return known.value != negated;
    }

    /// A local flag whose value tells the branches of `stmt` apart, and its value past the
    /// `then` branch: a `var` of the function's own, declared as `true` or `false` in the
    /// same pass of any loop as `stmt`, set to a literal only by statements of the branches
    /// themselves and to different values past each (a branch that does not set it leaves it as
    /// declared), its address never taken.
    fn correlated(f: Flow, stmt: Ast.Node.Index, branch: Ast.full.If) Context.Error!?struct { declaration: Model.Declaration.Id, then: bool } {
        const branches = [2]?Ast.Node.Index{ branch.ast.then_expr, branch.ast.else_expr.unwrap() };
        for (branches) |side| {
            const node = side orelse continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = f.tree.blockStatements(&buffer, node) orelse &[_]Ast.Node.Index{node};
            for (statements) |candidate| {
                const set = try f.setsFlag(candidate) orelse continue;
                const declared = try f.flagDeclared(set.declaration) orelse continue;
                if (!try f.flagWritesIn(set.declaration, branches)) continue;
                if (loopOf(f.model, f.tree, f.model.declarations[@backingInt(set.declaration)].node) != loopOf(f.model, f.tree, stmt)) continue;
                const then_value = try f.flagPast(branch.ast.then_expr, set.declaration) orelse declared;
                const else_value = if (branches[1]) |other| try f.flagPast(other, set.declaration) orelse declared else declared;
                if (then_value != else_value) return .{ .declaration = set.declaration, .then = then_value };
            }
        }
        return null;
    }

    /// `flag = true` or `flag = false` of a local, a store of a whole value known as the
    /// program compiles (`accesses.storesIn`'s site, `Facts.knownBool`): the flag's declaration
    /// and the value.
    fn setsFlag(f: Flow, stmt: Ast.Node.Index) Context.Error!?struct { declaration: Model.Declaration.Id, value: bool } {
        const site = for (try Facts.accesses.storesIn(f.c.facts, f.c.file)) |each| {
            if (each.node == stmt) break each;
        } else return null;
        if (site.kind != .set or site.part or site.through or site.reach != .exact) return null;
        const value = try f.c.facts.knownBool(f.c.file, site.value orelse return null) orelse return null;
        const declaration = switch (try f.c.facts.definition(f.c.file, site.target orelse return null)) {
            .decl => |decl| if (decl.file == f.c.file) decl.index else return null,
            .none, .unknown => return null,
        };
        const record = f.model.declarations[@backingInt(declaration)];
        if (record.kind != .variable or f.model.scopes[@backingInt(record.scope)].kind != .block) return null;
        return .{ .declaration = declaration, .value = value };
    }

    /// The value a `var` is declared with, where it is known as the program compiles.
    fn flagDeclared(f: Flow, declaration: Model.Declaration.Id) Context.Error!?bool {
        const variable = f.tree.fullVarDecl(f.model.declarations[@backingInt(declaration)].node) orelse return null;
        if (f.tree.tokenTag(variable.ast.mut_token) != .keyword_var) return null;
        return f.c.facts.knownBool(f.c.file, variable.ast.init_node.unwrap() orelse return null);
    }

    /// The value a branch leaves the flag at when it falls through: its last top-level setting.
    fn flagPast(f: Flow, node: Ast.Node.Index, declaration: Model.Declaration.Id) Context.Error!?bool {
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = f.tree.blockStatements(&buffer, node) orelse &[_]Ast.Node.Index{node};
        var value: ?bool = null;
        for (statements) |stmt| if (try f.setsFlag(stmt)) |set| {
            if (set.declaration == declaration) value = set.value;
        };
        return value;
    }

    /// Whether every write of the flag is a top-level setting in one of `branches` (`setsFlag`),
    /// and nothing takes its address or writes it otherwise, by its access sites
    /// (`accesses.reads` and `accesses.writes`).
    fn flagWritesIn(f: Flow, declaration: Model.Declaration.Id, branches: [2]?Ast.Node.Index) Context.Error!bool {
        const place: Facts.accesses.Place = .{ .declaration = .{ .file = f.c.file, .index = declaration } };
        for ([_]Facts.accesses.Each{ Facts.accesses.reads(f.c.facts, place, &.{f.c.file}), Facts.accesses.writes(f.c.facts, place, &.{f.c.file}) }) |start| {
            var found = start;
            while (try found.next()) |site| {
                if (site.reach != .exact) return false;
                switch (site.kind) {
                    .read, .init => {},
                    .update, .covered, .address => return false,
                    .set => {
                        const at = f.model.parentOf(site.node) orelse return false;
                        for (branches) |side| {
                            const branch = side orelse continue;
                            if (at == branch or site.node == branch) break;
                        } else return false;
                        if (try f.setsFlag(site.node) == null) return false;
                    },
                }
            }
        }
        return true;
    }

    /// A branch or a loop's body walked from `state`; a release it defers runs on every way
    /// out of it.
    fn block(f: Flow, node: Ast.Node.Index, state: State) Context.Error!Outcome {
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = f.tree.blockStatements(&buffer, node) orelse &[_]Ast.Node.Index{node};
        var outcome = try f.walk(statements, state);
        if (state == .deferred) return outcome;
        const paths = switch (outcome) {
            .paths => |*paths| paths,
            .split => |*split| split: {
                for (&split.when) |*each| if (each.* == .deferred) {
                    each.* = .released;
                };
                break :split &split.paths;
            },
            .uncertain => return outcome,
        };
        if (paths.falls == .deferred) paths.falls = .released;
        for ([_]*States{ &paths.breaks, &paths.continues }) |set| if (set.contains(.deferred)) {
            set.remove(.deferred);
            set.insert(.released);
        };
        return outcome;
    }

    /// A `while` or `for` loop from `state`: its body must come back to its start in `state`,
    /// and its ways out (its `break`s, its condition failing, its `else`) agree on where it goes on.
    fn repeat(f: Flow, stmt: Ast.Node.Index, state: State) Context.Error!Outcome {
        var inner = f;
        inner.loop = stmt;
        var heads: [2]Ast.Node.Index = @splat(.root);
        var head_count: usize = 0;
        var body: Ast.Node.Index = undefined;
        var otherwise: ?Ast.Node.Index = null;
        var bounded = true;
        var inputs: []const Ast.Node.Index = &.{};
        if (f.tree.fullWhile(stmt)) |loop| {
            heads[0] = loop.ast.cond_expr;
            head_count = 1;
            if (loop.ast.cont_expr.unwrap()) |cont| {
                heads[1] = cont;
                head_count = 2;
            }
            body = loop.ast.then_expr;
            otherwise = loop.ast.else_expr.unwrap();
            const cond = loop.ast.cond_expr;
            bounded = loop.payload_token != null or f.tree.nodeTag(cond) != .identifier or !std.mem.eql(u8, f.tree.tokenSlice(f.tree.nodeMainToken(cond)), "true");
        } else {
            const loop = f.tree.fullFor(stmt).?;
            inputs = loop.ast.inputs;
            body = loop.ast.then_expr;
            otherwise = loop.ast.else_expr.unwrap();
        }
        var out: Paths = .{};
        for (heads[0..head_count]) |head| {
            const paths = (try f.leave(head, state)).settled() orelse return .uncertain;
            out.breaks.setUnion(paths.breaks);
            out.continues.setUnion(paths.continues);
        }
        for (inputs) |input| {
            const paths = (try f.leave(input, state)).settled() orelse return .uncertain;
            out.breaks.setUnion(paths.breaks);
            out.continues.setUnion(paths.continues);
        }
        const looped = (try inner.block(body, state)).settled() orelse return .uncertain;
        if (looped.falls) |back| if (back != state) return .uncertain;
        if (!looped.continues.subsetOf(.initOne(state))) return .uncertain;
        var ways = looped.breaks;
        if (bounded) {
            if (otherwise) |node| {
                const paths = (try f.block(node, state)).settled() orelse return .uncertain;
                if (paths.falls) |next| ways.insert(next);
                out.breaks.setUnion(paths.breaks);
                out.continues.setUnion(paths.continues);
            } else ways.insert(state);
        }
        var it = ways.iterator();
        out.falls = it.next();
        if (it.next() != null) return .uncertain;
        return .{ .paths = out };
    }

    /// The state two paths agree on: one, or `passed` where the other released.
    fn meet(a: ?State, b: ?State) error{Differ}!?State {
        const x = a orelse return b;
        const y = b orelse return a;
        if (x == y) return x;
        if ((x == .passed and y == .released) or (x == .released and y == .passed)) return .passed;
        return error.Differ;
    }

    /// A statement or expression the walk does not enter, from `state`: how it uses the
    /// owner, then where it can jump. A `break` or `continue` of the walk's loop goes there; a
    /// `return`, a `try` or a jump out of the walk ends its path unless the owner is live; a
    /// jump to another loop or block of the walk is not followed. A member of the owner used
    /// where every path has released or transferred it is a finding.
    fn leave(f: Flow, node: Ast.Node.Index, state: State) Context.Error!Outcome {
        switch (try f.uses(node)) {
            .none => {},
            .members => if (state == .released) try f.c.at(cleanup, f.firstUse(node), "same local owner used after its cleanup or transfer on every path here"),
            .other => return .uncertain,
        }
        return f.jumps(node, state);
    }

    /// Where `node` can jump, from `state` (`leave`).
    fn jumps(f: Flow, node: Ast.Node.Index, state: State) Context.Error!Outcome {
        return f.jumpsAround(node, state, null);
    }

    /// `jumps`, where `node` moves the owner out at `move` (`kept`): a jump after the move,
    /// or a `try` of what holds it, finds the owner released.
    fn jumpsAround(f: Flow, node: Ast.Node.Index, state: State, move: ?Ast.Node.Index) Context.Error!Outcome {
        const first = f.tree.firstToken(node);
        const last = f.tree.lastToken(node);
        var out: Paths = .{ .falls = state };
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            switch (tag) {
                .@"return", .@"try", .@"break", .@"continue" => {},
                else => continue,
            }
            const jumping: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const main = f.tree.nodeMainToken(jumping);
            if (main < first or main > last) continue;
            const at: State = if (move) |m| if (f.after(jumping, m)) .released else state else state;
            const to: Jump = if (tag == .@"return" or tag == .@"try") .out else f.target(jumping, node);
            switch (to) {
                .inside => {},
                .loop_break => out.breaks.insert(at),
                .loop_continue => out.continues.insert(at),
                .out => {
                    const fails = (f.errdeferred or f.exits != null) and try failing(f.c, f.tree, jumping);
                    if (!try f.exit(main, fails, at)) return .uncertain;
                },
                .other => return .uncertain,
            }
        }
        switch (f.tree.nodeTag(node)) {
            .@"return", .@"break", .@"continue" => out.falls = null,
            else => {},
        }
        return .{ .paths = out };
    }

    /// An exit from the walk at `token` in `state`, on an error when `fails`: false where the
    /// walk cannot follow it, the owner live with nothing to release it. A function walked for
    /// a call records the state its error exits leave the owner in (`exits`); one that leaves
    /// it held gives it back to the caller.
    fn exit(f: Flow, token: Ast.TokenIndex, fails: bool, state: State) Context.Error!bool {
        if (f.errdeferred and fails) switch (state) {
            .released => try f.c.at(cleanup, token, "an errdefer releases the same local owner again on this error exit, after its cleanup or transfer"),
            .passed => return false,
            .live, .deferred => {},
        } else if (state == .live) {
            const record = f.exits orelse return false;
            if (!fails) return false;
            record.held = true;
            return true;
        }
        if (fails) if (f.exits) |record| {
            record.released = true;
        };
        return true;
    }

    /// Whether `jumping` leaves after `move` has run: it comes after it, or it is a `try` of
    /// what holds it.
    fn after(f: Flow, jumping: Ast.Node.Index, move: Ast.Node.Index) bool {
        if (f.tree.nodeMainToken(jumping) > f.tree.lastToken(move)) return true;
        if (f.tree.nodeTag(jumping) != .@"try") return false;
        const operand = f.tree.nodeData(jumping).node;
        return f.tree.firstToken(operand) <= f.tree.firstToken(move) and f.tree.lastToken(operand) >= f.tree.lastToken(move);
    }

    /// The paths on from `stmt` where it takes the owner from the walk, null where it does
    /// not. It takes it by a move it keeps (`kept`) where the result is returned, stored where
    /// the function does not hold it (`unheld`), or bound to a local that is the moved owner
    /// itself, which A003 follows from its own acquisition; or by a call given the owner's
    /// address that releases it (`consumed`), alone, tried, handled by `catch`, bound or
    /// returned. A jump before the move finds the owner live, one after it released; the
    /// call's failures find it as the call leaves it. Past the statement it is released.
    fn takes(f: Flow, stmt: Ast.Node.Index) Context.Error!?Outcome {
        const returned = f.tree.nodeTag(stmt) == .@"return";
        const bound = f.tree.fullVarDecl(stmt);
        const assigned = f.tree.nodeTag(stmt) == .assign;
        const node = (if (returned) f.tree.nodeData(stmt).opt_node.unwrap() else if (bound) |v| v.ast.init_node.unwrap() else if (assigned) f.tree.nodeData(stmt).node_and_node[1] else stmt) orelse return null;
        if (try f.kept(node)) |move| {
            const holds = returned or (assigned and try f.unheld(f.tree.nodeData(stmt).node_and_node[0])) or (bound != null and move == node);
            if (!holds) return null;
            var outcome = try f.jumpsAround(node, .live, move);
            switch (outcome) {
                .paths => |*paths| paths.falls = if (returned) null else .released,
                .split, .uncertain => {},
            }
            return outcome;
        }
        var call = node;
        var handler: ?Ast.Node.Index = null;
        switch (f.tree.nodeTag(node)) {
            .@"try" => call = f.tree.nodeData(node).node,
            .@"catch" => {
                const parts = f.tree.nodeData(node).node_and_node;
                call = parts[0];
                handler = parts[1];
            },
            else => {},
        }
        const taking = (try f.consumed(call)) orelse return null;
        // Its failures come after the function released the owner, or give it back.
        const failed: State = switch (taking) {
            .always => .released,
            .on_success => .live,
        };
        var paths = (try f.jumps(if (handler != null) call else node, failed)).settled() orelse return .uncertain;
        if (handler) |h| {
            const caught = (try f.block(h, failed)).settled() orelse return .uncertain;
            paths.breaks.setUnion(caught.breaks);
            paths.continues.setUnion(caught.continues);
            paths.falls = meet(.released, caught.falls) catch return .uncertain;
        } else if (returned and node == call and try f.c.facts.resolve(f.c.file, call) == .error_union) {
            // `return call(&owner)`: its error is returned as it comes.
            if (!try f.exit(f.tree.nodeMainToken(stmt), true, failed)) return .uncertain;
        }
        if (paths.falls != null) paths.falls = if (returned) null else .released;
        return .{ .paths = paths };
    }

    /// Whether `node` gives the owner by value through its `move`, which leaves the local
    /// consumed (`own.Owned.move`): `owner.move()`, or `if (owner) |o| o.move() else null` of
    /// an optional one, or of an optional pointer to one.
    fn moves(f: Flow, node: Ast.Node.Index) Context.Error!bool {
        if (f.kind != .owned or f.aggregate) return false;
        var buffer: [1]Ast.Node.Index = undefined;
        if (f.tree.fullCall(&buffer, node)) |call| return f.moveCall(call, null);
        const branch = f.tree.fullIf(node) orelse return false;
        const payload = branch.payload_token orelse return false;
        if (branch.error_token != null or !f.mine(branch.ast.cond_expr)) return false;
        const other = branch.ast.else_expr.unwrap() orelse return false;
        if (f.tree.nodeTag(other) != .identifier or !std.mem.eql(u8, f.tree.tokenSlice(f.tree.nodeMainToken(other)), "null")) return false;
        const call = f.tree.fullCall(&buffer, branch.ast.then_expr) orelse return false;
        return f.moveCall(call, payload);
    }

    /// `x.move()`, `x` the owner, or the capture `payload` names (`|o|` or `|*o|`).
    fn moveCall(f: Flow, call: Ast.full.Call, payload: ?Ast.TokenIndex) Context.Error!bool {
        if (call.ast.params.len != 0 or f.tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
        const data = f.tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!std.mem.eql(u8, try Model.identifier(f.c.allocator, f.tree.tokenSlice(data[1])), "move")) return false;
        const capture = payload orelse return f.mine(data[0]);
        if (f.tree.nodeTag(data[0]) != .identifier) return false;
        const ref = f.model.reference(data[0]) orelse return false;
        const token = f.model.declarations[@backingInt(ref.declaration orelse return false)].token;
        return token == capture or token == capture + 1;
    }

    /// The move (`moves`) `node`, a name of the owner, is the receiver or the optional of.
    fn moveOf(f: Flow, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
        const parent = f.model.parentOf(node) orelse return null;
        if (f.tree.nodeTag(parent) == .field_access) {
            const call = f.model.parentOf(parent) orelse return null;
            return if (try f.moves(call)) call else null;
        }
        return if (try f.moves(parent)) parent else null;
    }

    /// The move of the owner `value` keeps: `value` itself (`moves`), or one that a struct or
    /// array literal in it holds as a field or element, nested in turn. The owner is named
    /// nowhere else in `value` but through its members, before the move; null where it is.
    fn kept(f: Flow, value: Ast.Node.Index) Context.Error!?Ast.Node.Index {
        if (f.kind != .owned or f.aggregate) return null;
        const first = f.tree.firstToken(value);
        const last = f.tree.lastToken(value);
        var found: ?Ast.Node.Index = null;
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const main = f.tree.nodeMainToken(candidate);
            if (main < first or main > last or !f.mine(candidate)) continue;
            const move = (try f.moveOf(candidate)) orelse continue;
            if (found != null) return null;
            found = move;
        }
        const move = found orelse return null;
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const main = f.tree.nodeMainToken(candidate);
            if (main < first or main > last or !f.mine(candidate)) continue;
            if (main >= f.tree.firstToken(move) and main <= f.tree.lastToken(move)) continue;
            if (main > f.tree.firstToken(move)) return null;
            const parent = f.model.node_parents[i] orelse return null;
            if (fieldOf(f.tree, parent, candidate)) continue;
            if (f.tree.nodeTag(parent) != .field_access or f.tree.nodeData(parent).node_and_token[0] != candidate) return null;
            if (releaseName(f.kind, try Model.identifier(f.c.allocator, f.tree.tokenSlice(f.tree.nodeData(parent).node_and_token[1])))) return null;
        }
        var child = move;
        while (child != value) {
            const parent = f.model.parentOf(child) orelse return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const held = if (f.tree.fullStructInit(&buffer, parent)) |literal|
                std.mem.findScalar(Ast.Node.Index, literal.ast.fields, child) != null
            else if (f.tree.fullArrayInit(&buffer, parent)) |literal|
                std.mem.findScalar(Ast.Node.Index, literal.ast.elements, child) != null
            else
                f.tree.nodeTag(parent) == .grouped_expression;
            if (!held) return null;
            child = parent;
        }
        return move;
    }

    const Jump = enum { inside, loop_break, loop_continue, out, other };
    /// Where `jumping`, a `break` or `continue` within `root`, goes: to a target within `root`,
    /// out of or back to the walk's loop, out of the walk, or to another loop or block of it.
    fn target(f: Flow, jumping: Ast.Node.Index, root: Ast.Node.Index) Jump {
        const token = f.tree.nodeMainToken(jumping);
        const label: ?[]const u8 = if (f.tree.tokenTag(token + 1) == .colon) f.tree.tokenSlice(token + 2) else null;
        const again = f.tree.nodeTag(jumping) == .@"continue";
        var passed = jumping == root;
        var child = jumping;
        var at = f.model.parentOf(jumping);
        while (at) |parent| : ({
            child = parent;
            at = f.model.parentOf(parent);
        }) {
            if (f.targets(parent, child, label, again)) {
                if (!passed) return .inside;
                if (f.loop == parent) return if (again) .loop_continue else .loop_break;
                return if (f.within(parent)) .other else .out;
            }
            if (parent == root) passed = true;
        }
        return .out;
    }

    /// Whether a jump from `child` with `label` lands at `node`: an unlabeled one at the loop
    /// whose body or continue expression it is in, a labeled one at the loop, block or switch
    /// of that label.
    fn targets(f: Flow, node: Ast.Node.Index, child: Ast.Node.Index, label: ?[]const u8, again: bool) bool {
        if (f.tree.fullWhile(node)) |loop| {
            const name = label orelse return child == loop.ast.then_expr or child == loop.ast.cont_expr.unwrap();
            return if (loop.label_token) |t| std.mem.eql(u8, f.tree.tokenSlice(t), name) else false;
        }
        if (f.tree.fullFor(node)) |loop| {
            const name = label orelse return child == loop.ast.then_expr;
            return if (loop.label_token) |t| std.mem.eql(u8, f.tree.tokenSlice(t), name) else false;
        }
        const name = label orelse return false;
        if (f.tree.fullSwitch(node)) |s| return if (s.label_token) |t| std.mem.eql(u8, f.tree.tokenSlice(t), name) else false;
        if (again) return false;
        switch (f.tree.nodeTag(node)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                const brace = f.tree.nodeMainToken(node);
                return brace >= 2 and f.tree.tokenTag(brace - 1) == .colon and f.tree.tokenTag(brace - 2) == .identifier and std.mem.eql(u8, f.tree.tokenSlice(brace - 2), name);
            },
            else => return false,
        }
    }

    /// Whether `node` is inside the block the owner is declared in.
    fn within(f: Flow, node: Ast.Node.Index) bool {
        var at = f.model.parentOf(node);
        while (at) |parent| : (at = f.model.parentOf(parent)) {
            if (parent == f.scope) return true;
        }
        return false;
    }

    /// The operand and the handler of a statement that is, assigns or declares `a catch h` or
    /// `a orelse h`.
    fn handled(f: Flow, stmt: Ast.Node.Index) ?[2]Ast.Node.Index {
        const value = if (f.tree.fullVarDecl(stmt)) |v| v.ast.init_node.unwrap() orelse return null else if (Facts.accesses.formOf(f.tree.nodeTag(stmt)) == .assign) f.tree.nodeData(stmt).node_and_node[1] else stmt;
        return switch (Facts.accesses.formOf(f.tree.nodeTag(value))) {
            .@"catch", .@"orelse" => f.tree.nodeData(value).node_and_node,
            else => null,
        };
    }

    /// Whether `value` carries the owner itself: what a copy of it copies (`Facts.copiedParts`)
    /// is the owner, an element or the payload of it, or the result of a call it is an argument
    /// of by value (a field of a returned literal, an argument of the call that makes it). A
    /// member, an operand (`held != null`) or a type query (`@TypeOf(g)`) carries none; what
    /// does not resolve, unknown.
    fn carried(f: Flow, value: Ast.Node.Index) Context.Error!Is {
        const parts = try f.c.facts.copiedParts(f.c.file, value);
        if (parts.deep != null) return .{ .unknown = .unsupported };
        for (parts.places) |place| {
            // The owner, an element of it or its payload: its path's steps in from the place
            // to the first that is neither.
            var at = place;
            for ((try Facts.accesses.pathOf(f.c.facts, f.c.file, place)).steps) |each| {
                at = each.node;
                if (each.kind != .index and each.kind != .unwrap) break;
            }
            if (f.mine(at)) return .yes;
        }
        var out: Is = .no;
        for (parts.results) |result| {
            const call = (try Facts.calls.at(f.c.facts, f.c.file, result)) orelse continue;
            const args = switch (call.args) {
                .known => |each| each,
                .unknown => |why| {
                    out = .{ .unknown = why };
                    continue;
                },
            };
            // A receiver is the owner's own method, used through its members.
            const given = if (call.receiver == .bound) args[1..] else args;
            for (given) |arg| switch (try f.carried(arg)) {
                .yes => return .yes,
                .unknown => |why| out = .{ .unknown = why },
                .no => {},
            };
        }
        return out;
    }

    /// The local a statement of the owner's own block moves the owner into: a declaration
    /// whose initializer is a struct literal that holds the owner as a field's value, nowhere
    /// else, with the owner named nowhere after it. Its obligation is then that local's.
    fn movedInto(f: Flow, stmt: Ast.Node.Index) Context.Error!?Ast.TokenIndex {
        if (f.model.parentOf(stmt) != f.scope) return null;
        const variable = f.tree.fullVarDecl(stmt) orelse return null;
        const init = variable.ast.init_node.unwrap() orelse return null;
        var buffer: [2]Ast.Node.Index = undefined;
        if (f.tree.fullStructInit(&buffer, init) == null) return null;
        const first = f.tree.firstToken(init);
        const last = f.tree.lastToken(init);
        var held = false;
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (!f.mine(candidate)) continue;
            const main = f.tree.nodeMainToken(candidate);
            if (main > last) return null;
            if (main < first) continue;
            // A field's value of this literal or of one nested in it.
            const parent = f.model.node_parents[i] orelse return null;
            var literal_buffer: [2]Ast.Node.Index = undefined;
            const literal = f.tree.fullStructInit(&literal_buffer, parent) orelse return null;
            for (literal.ast.fields) |field| {
                if (field == candidate) break;
            } else return null;
            held = true;
        }
        if (!held) return null;
        return variable.ast.mut_token + 1;
    }

    /// The local of the owner's own block a statement copies the owner whole into, the owner
    /// named nowhere after it: `const copy = owner;`, `copy = owner;`, or its bytes copied
    /// (`@memcpy(std.mem.asBytes(&copy), std.mem.asBytes(&owner))`). The copy is then the owner.
    fn copiedInto(f: Flow, stmt: Ast.Node.Index) ?Ast.TokenIndex {
        if (f.model.parentOf(stmt) != f.scope) return null;
        const copy: Ast.TokenIndex, const value: Ast.Node.Index = if (f.tree.fullVarDecl(stmt)) |variable| .{
            variable.ast.mut_token + 1,
            variable.ast.init_node.unwrap() orelse return null,
        } else switch (f.tree.nodeTag(stmt)) {
            .assign => assign: {
                const place, const source = f.tree.nodeData(stmt).node_and_node;
                break :assign .{ f.localToken(place) orelse return null, source };
            },
            .builtin_call_two, .builtin_call_two_comma => bytes: {
                if (!std.mem.eql(u8, f.tree.tokenSlice(f.tree.nodeMainToken(stmt)), "@memcpy")) return null;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(f.tree, stmt, &buffer);
                if (args.len != 2) return null;
                const into = addressed(f.tree, args[0]) orelse return null;
                break :bytes .{ f.localToken(into) orelse return null, addressed(f.tree, args[1]) orelse return null };
            },
            else => return null,
        };
        if (!f.mine(value) or copy == f.token) return null;
        // The owner named nowhere after: the copy is its one holder.
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (f.mine(candidate) and f.tree.nodeMainToken(candidate) > f.tree.lastToken(stmt)) return null;
        }
        return copy;
    }

    /// The declaration token of a local of the owner's block `node` names.
    fn localToken(f: Flow, node: Ast.Node.Index) ?Ast.TokenIndex {
        if (f.tree.nodeTag(node) != .identifier) return null;
        const index = (f.model.reference(node) orelse return null).declaration orelse return null;
        const decl = f.model.declarations[@backingInt(index)];
        if (decl.kind != .variable or f.model.scopes[@backingInt(decl.scope)].node != f.scope) return null;
        return decl.token;
    }

    fn mine(f: Flow, node: Ast.Node.Index) bool {
        if (f.tree.nodeTag(node) != .identifier) return false;
        const ref = f.model.reference(node) orelse return false;
        const index = ref.declaration orelse return false;
        return f.model.declarations[@backingInt(index)].token == f.token;
    }

    const Use = enum { none, members, other };
    /// How `node` uses the owner: not at all, only through its members (a nested release
    /// counts as other), or otherwise.
    fn uses(f: Flow, node: Ast.Node.Index) Context.Error!Use {
        const first = f.tree.firstToken(node);
        const last = f.tree.lastToken(node);
        var found: Use = .none;
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const main = f.tree.nodeMainToken(candidate);
            if (main < first or main > last) continue;
            const ref = f.model.reference(candidate) orelse continue;
            const index = ref.declaration orelse continue;
            if (f.model.declarations[@backingInt(index)].token != f.token) continue;
            const parent = f.model.node_parents[i] orelse return .other;
            // Lent to a call that holds it again on every return: a borrow.
            if (f.tree.nodeTag(parent) == .address_of and try lent(f.c, f.c.file, parent, 0)) {
                found = .members;
                continue;
            }
            if (fieldOf(f.tree, parent, candidate)) {
                found = .members;
                continue;
            }
            // A std handle is a value: a copy given to a call that does not release that
            // parameter is lent to it.
            if (f.kind == .std_handle and try Shapes.lentArgument(f.c, cleanup, f.c.file, candidate)) {
                found = .members;
                continue;
            }
            // An element of an array of owners (`owners[0].value()`) is used as the owner is.
            var reached = candidate;
            var holder = parent;
            if (f.tree.nodeTag(parent) == .array_access and f.tree.nodeData(parent).node_and_node[0] == candidate) {
                reached = parent;
                holder = f.model.parentOf(parent) orelse return .other;
            }
            if (f.tree.nodeTag(holder) != .field_access or f.tree.nodeData(holder).node_and_token[0] != reached) return .other;
            const member = try Model.identifier(f.c.allocator, f.tree.tokenSlice(f.tree.nodeData(holder).node_and_token[1]));
            // A move hands the owner on, as a release ends it (`kept`).
            if (releaseName(f.kind, member) or (f.kind == .owned and std.mem.eql(u8, member, "move"))) return .other;
            found = .members;
        }
        return found;
    }

    /// `owner = x.init(...)`, `x.adopt(...)` or any acquisition of a guard: live again;
    /// unknown where what the call gives does not resolve.
    fn reacquired(f: Flow, stmt: Ast.Node.Index) Context.Error!Is {
        if (f.tree.nodeTag(stmt) != .assign) return .no;
        const data = f.tree.nodeData(stmt).node_and_node;
        const index = Contract.local(f.c, data[0]) orelse return .no;
        if (f.model.declarations[@backingInt(index)].token != f.token) return .no;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const value = if (f.tree.nodeTag(data[1]) == .@"try") f.tree.nodeData(data[1]).node else data[1];
        const call = f.tree.fullCall(&call_buffer, value) orelse return .no;
        if (f.tree.nodeTag(call.ast.fn_expr) != .field_access) return .no;
        const operation = try Model.identifier(f.c.allocator, f.tree.tokenSlice(f.tree.nodeData(call.ast.fn_expr).node_and_token[1]));
        if (std.mem.eql(u8, operation, "init") or std.mem.eql(u8, operation, "adopt") or Contract.acquisition(operation)) return .yes;
        return givesOwner(f.c, value);
    }

    /// `owner.handOff()` kept in a local, assigned or returned: the guard's release passes to
    /// the hand-off, an owner of its own, released once by its `release` (a local of it is
    /// walked from its acquisition as any owner is, the caller's where it is returned).
    /// Discarded (`_ = owner.handOff()`), the hand-off is the leak, reported there.
    fn handedOff(f: Flow, stmt: Ast.Node.Index) Context.Error!bool {
        const value = if (f.tree.fullVarDecl(stmt)) |v| v.ast.init_node.unwrap() orelse return false else if (f.tree.nodeTag(stmt) == .@"return") f.tree.nodeData(stmt).opt_node.unwrap() orelse return false else if (f.tree.nodeTag(stmt) == .assign) blk: {
            break :blk f.tree.nodeData(stmt).node_and_node[1];
        } else return false;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = f.tree.fullCall(&buffer, value) orelse return false;
        if (f.tree.nodeTag(call.ast.fn_expr) != .field_access or call.ast.params.len != 0) return false;
        const data = f.tree.nodeData(call.ast.fn_expr).node_and_token;
        const index = Contract.local(f.c, data[0]) orelse return false;
        return f.model.declarations[@backingInt(index)].token == f.token and std.mem.eql(u8, try Model.identifier(f.c.allocator, f.tree.tokenSlice(data[1])), "handOff");
    }

    /// A statement that is a call, or keeps or tries its result, with the owner itself among
    /// its arguments and named nowhere else in the statement, to a function outside the
    /// program (std's containers): one that takes an owner by value keeps it, as a `put` or an
    /// `append` does. A function of the program's own, in a file the run selected or not, a
    /// dependency's among them, is not walked for what it does with its parameter, so a call to
    /// one stays undecided.
    fn argument(f: Flow, stmt: Ast.Node.Index) Context.Error!bool {
        var value = if (f.tree.fullVarDecl(stmt)) |v| v.ast.init_node.unwrap() orelse return false else if (f.tree.nodeTag(stmt) == .assign) f.tree.nodeData(stmt).node_and_node[1] else stmt;
        if (f.tree.nodeTag(value) == .@"try") value = f.tree.nodeData(value).node;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = f.tree.fullCall(&buffer, value) orelse return false;
        var given: usize = 0;
        for (call.ast.params) |param| {
            if (f.mine(param)) given += 1;
        }
        if (given != 1) return false;
        // One that may call another function is read as the program's: undecided.
        const callee = switch (try calledFunction(f.c, f.c.file, value)) {
            .function => |function| function,
            .unknown => return false,
        };
        if (try Program.owns(f.c, callee.file)) return false;
        const first = f.tree.firstToken(stmt);
        const last = f.tree.lastToken(stmt);
        var named: usize = 0;
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const main = f.tree.nodeMainToken(candidate);
            if (main >= first and main <= last and f.mine(candidate)) named += 1;
        }
        return named == 1;
    }

    /// How `value`, a call of a function of the program's own with the owner's address among
    /// its arguments (`c.owned(true, &owner, fail)`, or the pointer a walk of such a function
    /// has, passed on) and the owner named nowhere else in it, takes the owner: where the
    /// function releases what that parameter points at on every path, `always`; where it does
    /// on every return and every error exit leaves it held, `on_success`. Its body is walked as
    /// this walk is, the parameter the owner, a `comptime` `bool` parameter the call passes a
    /// literal as known, in a reading of the function's file that reports nothing there. A
    /// finding or an undecided site in that reading, a path that leaves it held but an error
    /// exit, or error exits that disagree, and the call does not take it.
    fn consumed(f: Flow, value: Ast.Node.Index) Context.Error!?Taking {
        if (f.depth == 8) return null;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = f.tree.fullCall(&buffer, value) orelse return null;
        // The owner's address: `&owner`, or the pointer itself where the walk has one.
        const position = for (call.ast.params, 0..) |param, i| {
            if (if (f.pointer) f.mine(param) else Facts.accesses.formOf(f.tree.nodeTag(param)) == .address_of and f.mine(f.tree.nodeData(param).node)) break i;
        } else return null;
        const first = f.tree.firstToken(value);
        const last = f.tree.lastToken(value);
        var named: usize = 0;
        for (0..f.tree.nodes.len) |i| {
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const main = f.tree.nodeMainToken(candidate);
            if (main >= first and main <= last and f.mine(candidate)) named += 1;
        }
        if (named != 1) return null;
        // One that may call another function does not take it: the address handed on is
        // undecided.
        const function = switch (try calledFunction(f.c, f.c.file, value)) {
            .function => |called| called,
            .unknown => return null,
        };
        if (!try Program.owns(f.c, function.file)) return null;
        const model = &f.c.project.at(function.file).model;
        const record = model.declarations[@backingInt(function.index)];
        if (record.kind != .function) return null;
        const written = &f.c.project.at(function.file).file.tree;
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const proto = written.fullFnProto(&proto_buffer, record.node) orelse return null;
        const whole_fn = if (written.nodeTag(record.node) == .fn_decl) record.node else model.parentOf(record.node) orelse return null;
        if (written.nodeTag(whole_fn) != .fn_decl) return null;
        var count: usize = 0;
        var counting = proto.iterate(written);
        while (counting.next()) |_| count += 1;
        // A method called on a value takes the value as its first parameter.
        const skip: usize = if (count == call.ast.params.len + 1) 1 else if (count == call.ast.params.len) 0 else return null;
        var token: ?Ast.TokenIndex = null;
        var known: ?Known = null;
        var it = proto.iterate(written);
        var at: usize = 0;
        while (it.next()) |param| : (at += 1) {
            if (at == position + skip) token = param.name_token;
            if (known != null or at < skip or param.comptime_noalias == null or written.tokenTag(param.comptime_noalias.?) != .keyword_comptime) continue;
            const truth = try f.c.facts.knownBool(f.c.file, call.ast.params[at - skip]) orelse continue;
            const name = param.name_token orelse continue;
            for (model.declarations, 0..) |d, i| if (d.kind == .parameter and d.token == name) {
                known = .{ .flag = @fromBackingInt(@intCast(i)), .value = truth };
            };
        }
        var heard: Heard = .{ .outer = f.c.sink };
        var probe = f.c.*;
        probe.file = function.file;
        probe.sink = &heard.sink;
        const body = written.nodeData(whole_fn).node_and_node[1];
        var seen: Exits = .{};
        const walker: Flow = .{ .c = &probe, .tree = written, .model = model, .token = token orelse return null, .kind = f.kind, .scope = body, .known = known, .depth = f.depth + 1, .pointer = true, .exits = &seen };
        var block_buffer: [2]Ast.Node.Index = undefined;
        const statements = written.blockStatements(&block_buffer, body) orelse return null;
        const outcome = try walker.walk(statements, .live);
        if (heard.any) return null;
        const paths = outcome.settled() orelse return null;
        if (paths.breaks.count() != 0 or paths.continues.count() != 0) return null;
        if (paths.falls) |end| if (end != .released and end != .deferred) return null;
        if (!seen.held) return .always;
        return if (seen.released) null else .on_success;
    }

    /// `place = owner` into storage the function does not hold (`unheld`), the owner itself by
    /// value: a transfer by assignment, the obligation then the place's holder's.
    fn stored(f: Flow, stmt: Ast.Node.Index) Context.Error!bool {
        if (f.tree.nodeTag(stmt) != .assign) return false;
        const data = f.tree.nodeData(stmt).node_and_node;
        if (!f.mine(data[1])) return false;
        return f.unheld(data[0]);
    }

    /// Whether `node` is storage the function does not hold: reached through a pointer (`p.*`,
    /// a field or element of a pointer, a slice's element), a parameter's (a field of one is
    /// assignable only through a pointer) or a container's variable. A field of a local value
    /// is the local's, not followed.
    fn unheld(f: Flow, node: Ast.Node.Index) Context.Error!bool {
        var place = node;
        while (true) switch (f.tree.nodeTag(place)) {
            .deref => return true,
            .field_access, .array_access, .unwrap_optional => {
                const base = switch (f.tree.nodeTag(place)) {
                    .field_access => f.tree.nodeData(place).node_and_token[0],
                    .array_access => f.tree.nodeData(place).node_and_node[0],
                    else => f.tree.nodeData(place).node_and_token[0],
                };
                switch (try f.c.facts.resolve(f.c.file, base)) {
                    .pointer => return true,
                    .unknown => return false,
                    else => place = base,
                }
            },
            .identifier => {
                const ref = f.model.reference(place) orelse return false;
                const declaration = f.model.declarations[@backingInt(ref.declaration orelse return false)];
                return switch (declaration.kind) {
                    .parameter => true,
                    .variable => switch (f.model.scopes[@backingInt(declaration.scope)].kind) {
                        .file, .container => true,
                        else => false,
                    },
                    else => false,
                };
            },
            else => return false,
        };
    }

    /// Whether a `defer` or `errdefer` body releases the owner: the release itself, or a block
    /// that makes it once at its top level, the owner named before it only through its members
    /// and not at all after it.
    fn releasesIn(f: Flow, body: Ast.Node.Index) Context.Error!bool {
        if (try release(f.c, body, f.token, f.kind)) return true;
        // `defer session.releaseWrite(&held)`: a function that releases it on every path.
        if (try f.consumed(body) == .always) return true;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = f.tree.blockStatements(&buffer, body) orelse return false;
        var released = false;
        for (statements) |stmt| {
            if (!released and try release(f.c, stmt, f.token, f.kind)) {
                released = true;
                continue;
            }
            switch (try f.uses(stmt)) {
                .none => {},
                .members => if (released) return false,
                .other => return false,
            }
        }
        return released;
    }

    /// The first token in `node` naming the owner.
    fn firstUse(f: Flow, node: Ast.Node.Index) Ast.TokenIndex {
        const first = f.tree.firstToken(node);
        const last = f.tree.lastToken(node);
        var found = last;
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const main = f.tree.nodeMainToken(candidate);
            if (main >= first and main <= found and f.mine(candidate)) found = main;
        }
        return found;
    }

    /// `owner.deinit()` of a result obligation: the check that its discharge came.
    fn tornDown(f: Flow, stmt: Ast.Node.Index) Context.Error!bool {
        const name = teardown(f.kind) orelse return false;
        return std.mem.eql(u8, (try ownerCall(f.c, stmt, f.token)) orelse return false, name);
    }

    /// `_ = &owner;`
    fn discardedAddress(f: Flow, stmt: Ast.Node.Index) bool {
        if (f.tree.nodeTag(stmt) != .assign) return false;
        const data = f.tree.nodeData(stmt).node_and_node;
        if (f.tree.nodeTag(data[0]) != .identifier or !std.mem.eql(u8, f.tree.tokenSlice(f.tree.nodeMainToken(data[0])), "_") or f.tree.nodeTag(data[1]) != .address_of) return false;
        const index = Contract.local(f.c, f.tree.nodeData(data[1]).node) orelse return false;
        return f.model.declarations[@backingInt(index)].token == f.token;
    }
};

/// What a reading of another file for a call's sake heard: findings and undecided sites there,
/// kept from the report as that file's own.
const Heard = struct {
    any: bool = false,
    /// The run's own sink, which knows each file's configuration.
    outer: *Context.Sink,
    sink: Context.Sink = .{ .diagnostic = diagnostic, .coverage = coverage, .config = config },

    fn config(sink: *Context.Sink, file: @import("Project.zig").FileId) @import("Rule.zig").Config {
        const heard: *Heard = @fieldParentPtr("sink", sink);
        return heard.outer.config(heard.outer, file);
    }
    fn diagnostic(sink: *Context.Sink, _: Rule, _: u32, _: u32, _: []const u8, _: []const Report.Span, _: []const Report.Edit) Context.Error!void {
        const heard: *Heard = @fieldParentPtr("sink", sink);
        heard.any = true;
    }
    fn coverage(sink: *Context.Sink, _: Report.Coverage) Context.Error!void {
        const heard: *Heard = @fieldParentPtr("sink", sink);
        heard.any = true;
    }
};

/// Whether `parent` is `@field(node, name)`: a member of `node` named at compile time.
fn fieldOf(tree: *const Ast, parent: Ast.Node.Index, node: Ast.Node.Index) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, parent, &buffer);
    return args.len == 2 and args[0] == node and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parent)), "@field");
}

/// Whether `argument`, a guard's address or a pointer to a guard, is lent by the call it is an
/// argument of: to an aegis condition's `wait` or `waitUncancelable`, which release the guard
/// while they wait and hold it again on every return, or to a function of the program's own
/// that hands it back held on every path (`Loan`).
fn lent(c: *Context, file: Project.FileId, argument: Ast.Node.Index, depth: u8) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const call_node = model.parentOf(argument) orelse return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, call_node) orelse return false;
    const position = for (call.ast.params, 0..) |param, i| {
        if (param == argument) break i;
    } else return false;
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        const data = tree.nodeData(call.ast.fn_expr).node_and_token;
        const name = try Model.identifier(c.allocator, tree.tokenSlice(data[1]));
        if (std.mem.eql(u8, name, "wait") or std.mem.eql(u8, name, "waitUncancelable")) {
            const k = (try Contract.kind(c, file, data[0], 0)) orelse switch (try typed(c, try c.facts.resolve(file, data[0]), 0)) {
                .owner => |owned| owned,
                .other, .unknown => null,
            };
            if (k == .condition) return true;
        }
        // A secret's writer borrows the owner it writes into; the owner keeps its release.
        if (std.mem.eql(u8, name, "init") and try Contract.kind(c, file, data[0], 0) == .bytes_writer) return true;
    }
    if (depth == 8) return false;
    // One that may call another function does not lend it: a use the walk leaves undecided.
    const function = switch (try calledFunction(c, file, call_node)) {
        .function => |called| called,
        .unknown => return false,
    };
    if (try c.inLibrary(Contract.library, function.file)) return false;
    const record = c.project.at(function.file).model.declarations[@backingInt(function.index)];
    if (record.kind != .function) return false;
    const written = &c.project.at(function.file).file.tree;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = written.fullFnProto(&proto_buffer, record.node) orelse return false;
    // The declaration's node is its prototype, or the whole declaration; its body is the latter's.
    const whole = if (written.nodeTag(record.node) == .fn_decl) record.node else c.project.at(function.file).model.parentOf(record.node) orelse return false;
    if (written.nodeTag(whole) != .fn_decl) return false;
    var params: [32]Ast.TokenIndex = @splat(0);
    var count: usize = 0;
    var it = proto.iterate(written);
    while (it.next()) |param| {
        if (count == params.len) return false;
        params[count] = param.name_token orelse return false;
        count += 1;
    }
    // A method called on a value takes the value as its first parameter.
    const skip: usize = if (count == call.ast.params.len + 1) 1 else if (count == call.ast.params.len) 0 else return false;
    const loan: Loan = .{ .c = c, .file = function.file, .tree = written, .model = &c.project.at(function.file).model, .token = params[position + skip], .depth = depth + 1 };
    const body = written.nodeData(whole).node_and_node[1];
    var block_buffer: [2]Ast.Node.Index = undefined;
    const statements = written.blockStatements(&block_buffer, body) orelse return false;
    return switch (try loan.walk(statements, .live)) {
        .falls => |state| state == .live,
        .ends => true,
        .fails => false,
    };
}

/// A function that borrows a guard through its parameter `token`: whether every path hands it
/// back held. The guard starts held; `p.deinit(...)` releases it and `p.* = x.acquire...(...)`
/// holds it again; a return, a `try` or the end while released fails, as does any use while
/// released, a deferred release, or a use but its members or a loan on. A loop's body must
/// leave it as it found it held; a `break` or `continue` while released fails.
const Loan = struct {
    c: *Context,
    file: Project.FileId,
    tree: *const Ast,
    model: *const Model,
    token: Ast.TokenIndex,
    depth: u8,

    const State = enum { live, released };
    const Outcome = union(enum) { falls: State, ends, fails };

    fn walk(l: Loan, statements: []const Ast.Node.Index, start: State) Context.Error!Outcome {
        var state = start;
        for (statements) |stmt| {
            const tag = l.tree.nodeTag(stmt);
            if (state == .released) {
                if (try l.reacquired(stmt)) {
                    state = .live;
                    continue;
                }
                if (try l.uses(stmt) != .none or exits(l.tree, l.model, stmt)) return .fails;
                continue;
            }
            if (tag == .@"defer" or tag == .@"errdefer") {
                if (try l.uses(l.tree.nodeData(stmt).node) != .none) return .fails;
                continue;
            }
            if (l.releases(stmt)) {
                state = .released;
                continue;
            }
            if (l.tree.fullIf(stmt)) |branch| {
                if (try l.uses(branch.ast.cond_expr) == .other or exits(l.tree, l.model, branch.ast.cond_expr)) return .fails;
                const then_outcome = try l.walkBranch(branch.ast.then_expr);
                const else_outcome: Outcome = if (branch.ast.else_expr.unwrap()) |other| try l.walkBranch(other) else .{ .falls = .live };
                switch (join(then_outcome, else_outcome)) {
                    .falls => |next| state = next,
                    .ends => return .ends,
                    .fails => return .fails,
                }
                continue;
            }
            if (l.tree.fullWhile(stmt)) |loop| {
                if (try l.uses(loop.ast.cond_expr) == .other) return .fails;
                if (loop.ast.cont_expr.unwrap()) |cont| if (try l.uses(cont) == .other) return .fails;
                if (try l.loopBody(loop.ast.then_expr) == .fails) return .fails;
                if (loop.ast.else_expr.unwrap()) |other| if (try l.uses(other) == .other) return .fails;
                continue;
            }
            if (l.tree.fullFor(stmt)) |loop| {
                for (loop.ast.inputs) |input| if (try l.uses(input) == .other) return .fails;
                if (try l.loopBody(loop.ast.then_expr) == .fails) return .fails;
                if (loop.ast.else_expr.unwrap()) |other| if (try l.uses(other) == .other) return .fails;
                continue;
            }
            // Held, it may be read, lent, returned with or left by an exit.
            if (try l.uses(stmt) == .other) return .fails;
        }
        return .{ .falls = state };
    }

    fn walkBranch(l: Loan, node: Ast.Node.Index) Context.Error!Outcome {
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = l.tree.blockStatements(&buffer, node) orelse &[_]Ast.Node.Index{node};
        const outcome = try l.walk(statements, .live);
        if (outcome == .falls and outcome.falls == .released and statements.len != 0 and endsInExit(l.tree, statements[statements.len - 1])) return .fails;
        if (outcome == .falls and outcome.falls == .live and statements.len != 0 and endsInExit(l.tree, statements[statements.len - 1])) return .ends;
        return outcome;
    }

    /// A loop's body: held when it starts, it must be held when it ends or loops again.
    fn loopBody(l: Loan, node: Ast.Node.Index) Context.Error!Outcome {
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = l.tree.blockStatements(&buffer, node) orelse &[_]Ast.Node.Index{node};
        return switch (try l.walk(statements, .live)) {
            .falls => |state| if (state == .live) .{ .falls = .live } else .fails,
            .ends => .{ .falls = .live },
            .fails => .fails,
        };
    }

    fn join(a: Outcome, b: Outcome) Outcome {
        if (a == .fails or b == .fails) return .fails;
        if (a == .ends) return b;
        if (b == .ends) return a;
        return if (a.falls == b.falls) a else .fails;
    }

    fn mine(l: Loan, node: Ast.Node.Index) bool {
        if (l.tree.nodeTag(node) != .identifier) return false;
        const ref = l.model.reference(node) orelse return false;
        const index = ref.declaration orelse return false;
        return l.model.declarations[@backingInt(index)].token == l.token;
    }

    /// `p.deinit(...)`.
    fn releases(l: Loan, stmt: Ast.Node.Index) bool {
        var buffer: [1]Ast.Node.Index = undefined;
        const call = l.tree.fullCall(&buffer, stmt) orelse return false;
        if (l.tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
        const data = l.tree.nodeData(call.ast.fn_expr).node_and_token;
        return l.mine(data[0]) and std.mem.eql(u8, l.tree.tokenSlice(data[1]), "deinit");
    }

    /// `p.* = x.acquire...(...)`.
    fn reacquired(l: Loan, stmt: Ast.Node.Index) Context.Error!bool {
        if (l.tree.nodeTag(stmt) != .assign) return false;
        const data = l.tree.nodeData(stmt).node_and_node;
        if (l.tree.nodeTag(data[0]) != .deref or !l.mine(l.tree.nodeData(data[0]).node)) return false;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const value = if (l.tree.nodeTag(data[1]) == .@"try") l.tree.nodeData(data[1]).node else data[1];
        const call = l.tree.fullCall(&call_buffer, value) orelse return false;
        if (l.tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
        return Contract.acquisition(try Model.identifier(l.c.allocator, l.tree.tokenSlice(l.tree.nodeData(call.ast.fn_expr).node_and_token[1])));
    }

    const Use = enum { none, members, other };
    /// How `node` uses the borrowed guard: not at all, through its members or by lending it on
    /// (a nested `deinit` is other), or otherwise.
    fn uses(l: Loan, node: Ast.Node.Index) Context.Error!Use {
        const first = l.tree.firstToken(node);
        const last = l.tree.lastToken(node);
        var found: Use = .none;
        for (l.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const main = l.tree.nodeMainToken(candidate);
            if (main < first or main > last or !l.mine(candidate)) continue;
            const parent = l.model.node_parents[i] orelse return .other;
            if (l.tree.nodeTag(parent) == .field_access and l.tree.nodeData(parent).node_and_token[0] == candidate) {
                if (std.mem.eql(u8, l.tree.tokenSlice(l.tree.nodeData(parent).node_and_token[1]), "deinit")) return .other;
                found = .members;
                continue;
            }
            if (try lent(l.c, l.file, candidate, l.depth)) {
                found = .members;
                continue;
            }
            return .other;
        }
        return found;
    }
};

/// Whether `node` can leave the block it is in: a `return`, a `try`, or a `break` or `continue`
/// that is labeled or not inside a loop within `node`.
fn exits(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    for (first..last + 1) |raw_token| {
        const token: Ast.TokenIndex = @intCast(raw_token);
        switch (tree.tokenTag(token)) {
            .keyword_return, .keyword_try => return true,
            .keyword_break, .keyword_continue => {
                if (tree.tokenTag(token + 1) == .colon) return true;
                if (!insideLoop(tree, model, token, node)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn insideLoop(tree: *const Ast, model: *const Model, token: Ast.TokenIndex, root: Ast.Node.Index) bool {
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break" and tag != .@"continue") continue;
        if (tree.nodeMainToken(@fromBackingInt(@intCast(i))) != token) continue;
        var at = model.node_parents[i];
        while (at) |parent| : (at = model.parentOf(parent)) {
            if (tree.fullWhile(parent) != null or tree.fullFor(parent) != null) return true;
            if (parent == root) return false;
        }
        return false;
    }
    return false;
}

/// Whether `jumping`, a `return` or a `try`, leaves by an error, which an `errdefer` sees: a
/// `try`, or a `return` of an error (`error.Name`, or a value of an error set, such as a call
/// that maps one).
fn failing(c: *Context, tree: *const Ast, jumping: Ast.Node.Index) Context.Error!bool {
    if (tree.nodeTag(jumping) == .@"try") return true;
    const value = tree.nodeData(jumping).opt_node.unwrap() orelse return false;
    if (try c.facts.literalOf(c.file, value)) |literal| if (literal == .error_value) return true;
    return try c.facts.resolve(c.file, value) == .error_set;
}

/// The innermost `while` or `for` around `node` within its function, whose passes it runs in.
fn loopOf(model: *const Model, tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    var child = node;
    var at = model.parentOf(node);
    while (at) |parent| : ({
        child = parent;
        at = model.parentOf(parent);
    }) {
        if (tree.nodeTag(parent) == .fn_decl) return null;
        if (tree.fullWhile(parent)) |loop| {
            if (child == loop.ast.then_expr or child == loop.ast.cont_expr.unwrap() or child == loop.ast.cond_expr) return parent;
        } else if (tree.fullFor(parent)) |loop| if (child == loop.ast.then_expr) return parent;
    }
    return null;
}

fn endsInExit(tree: *const Ast, stmt: Ast.Node.Index) bool {
    return switch (tree.nodeTag(stmt)) {
        .@"return", .@"break", .@"continue", .unreachable_literal => true,
        else => false,
    };
}
/// `owner.<release>(...)`: the call that ends the obligation of an owner of kind `k`.
fn release(c: *Context, node: Ast.Node.Index, token: Ast.TokenIndex, k: Contract.Kind) Context.Error!bool {
    if (try releasedEach(c, node, token, k)) return true;
    return releaseName(k, (try ownerCall(c, node, token)) orelse return false);
}
/// `for (&owners) |*owner| owner.deinit();`: a loop over the local array `token` declares,
/// whose one statement releases each element through its pointer capture.
fn releasedEach(c: *Context, node: Ast.Node.Index, token: Ast.TokenIndex, k: Contract.Kind) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    const loop = tree.fullFor(node) orelse return false;
    if (loop.ast.inputs.len != 1 or loop.ast.else_expr != .none or loop.label_token != null) return false;
    const input = loop.ast.inputs[0];
    if (tree.nodeTag(input) != .address_of) return false;
    const index = Contract.local(c, tree.nodeData(input).node) orelse return false;
    if (c.project.at(c.file).model.declarations[@backingInt(index)].token != token) return false;
    if (tree.tokenTag(loop.payload_token) != .asterisk) return false;
    var body = loop.ast.then_expr;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, body)) |statements| {
        if (statements.len != 1) return false;
        body = statements[0];
    }
    return releaseName(k, (try ownerCall(c, body, loop.payload_token + 1)) orelse return false);
}
/// The member `node` calls on the local `token` declares, if it is such a call.
fn ownerCall(c: *Context, node: Ast.Node.Index, token: Ast.TokenIndex) Context.Error!?[]const u8 {
    const tree = try c.project.syntax(try c.source());
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const data = tree.nodeData(call.ast.fn_expr).node_and_token;
    const index = Contract.local(c, data[0]) orelse return null;
    if (c.project.at(c.file).model.declarations[@backingInt(index)].token != token) return null;
    return try Model.identifier(c.allocator, tree.tokenSlice(data[1]));
}
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
    const tree = try c.project.syntax(try c.source());
    switch (tree.nodeTag(node)) {
        .call_one, .call_one_comma, .call, .call_comma => return try raw(c, node) or try rawBytes(c, node, seen),
        .@"try", .@"comptime" => return rawValue(c, tree.nodeData(node).node, seen),
        .grouped_expression => return rawValue(c, tree.nodeData(node).node_and_token[0], seen),
        .@"orelse", .@"catch" => {
            const sides = tree.nodeData(node).node_and_node;
            return try rawValue(c, sides[0], seen) or try rawValue(c, sides[1], seen);
        },
        .@"if", .if_simple => {
            const branch = tree.fullIf(node).?; // unreachable: the tag is an if's
            if (try rawValue(c, branch.ast.then_expr, seen)) return true;
            const otherwise = branch.ast.else_expr.unwrap() orelse return false;
            return rawValue(c, otherwise, seen);
        },
        .@"switch", .switch_comma => {
            const choice = tree.fullSwitch(node).?; // unreachable: the tag is a switch's
            for (choice.ast.cases) |case| if (try rawValue(c, tree.fullSwitchCase(case).?.ast.target_expr, seen)) return true; // unreachable: a switch's cases are cases
            return false;
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => return rawBreaks(c, node, seen),
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            // The value unchanged, or in each lane.
            if (std.mem.eql(u8, name, "@as")) return args.len == 2 and try rawValue(c, args[1], seen);
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
        .field_access => {
            const data = tree.nodeData(node).node_and_token;
            if (std.mem.eql(u8, tree.tokenSlice(data[1]), "len")) return false;
            return rawValue(c, data[0], seen);
        },
        .unwrap_optional => return rawValue(c, tree.nodeData(node).node_and_token[0], seen),
        .deref, .address_of => return rawValue(c, tree.nodeData(node).node, seen),
        .array_access => return rawValue(c, tree.nodeData(node).node_and_node[0], seen),
        .identifier => {
            const index = Contract.local(c, node) orelse return false;
            for (seen) |s| if (s == index) return false;
            const model = &c.project.at(c.file).model;
            const decl = model.declarations[@backingInt(index)];
            const followed = try std.mem.concat(c.allocator, Model.Declaration.Id, &.{ seen, &.{index} });
            // A capture: of what the `if`, loop or `switch` reads.
            if (decl.kind == .capture) return if (c.facts.captureSource(c.file, decl.node)) |source| rawValue(c, source, followed) else false;
            if (decl.kind != .variable) return false;
            const v = tree.fullVarDecl(decl.node) orelse return false;
            if (v.ast.init_node.unwrap()) |init| {
                if (try rawValue(c, init, followed)) return true;
            } else if (model.parentOf(decl.node)) |parent| if (tree.nodeTag(parent) == .assign_destructure) {
                // `const a, const b = .{ s.raw(), 0 };`: what is destructured.
                if (try rawValue(c, tree.assignDestructure(parent).ast.value_expr, followed)) return true;
            };
            if (tree.tokenTag(v.ast.mut_token) != .keyword_var) return false;
            // Anything put in it, whole or in a part, by any assignment, a destructure, or a
            // copy of bytes into it (`@memcpy(std.mem.asBytes(&v), std.mem.asBytes(&i))`).
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (tag == .assign_destructure) {
                    const destructure = tree.assignDestructure(at);
                    for (destructure.ast.variables) |target| {
                        const root = placeRoot(tree, target) orelse continue;
                        if (Contract.local(c, root) == index and try rawValue(c, destructure.ast.value_expr, followed)) return true;
                    }
                    continue;
                }
                if (try Facts.accesses.copyAt(c.facts, c.file, at)) |copy| {
                    const root = placeRoot(tree, copy.into.node()) orelse continue;
                    if (Contract.local(c, root) != index) continue;
                    if (try rawValue(c, copy.from.node(), followed) or try requiredOwner(c, copy.from.node(), scalar, tree.nodeMainToken(at)) == .scalar) return true;
                    continue;
                }
                if (!assigning(tag)) continue;
                const sides = tree.nodeData(at).node_and_node;
                const root = placeRoot(tree, sides[0]) orelse continue;
                if (Contract.local(c, root) != index) continue;
                if (try rawValue(c, sides[1], followed)) return true;
            }
            return false;
        },
        else => {
            // A literal holding it in a field or an element.
            var buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullStructInit(&buffer, node)) |literal| {
                for (literal.ast.fields) |field| if (try rawValue(c, field, seen)) return true;
                return false;
            }
            if (tree.fullArrayInit(&buffer, node)) |literal| {
                for (literal.ast.elements) |element| if (try rawValue(c, element, seen)) return true;
                return false;
            }
            return false;
        },
    }
}

/// Whether a `break` out of the labeled block `node` may give a raw value.
fn rawBreaks(c: *Context, node: Ast.Node.Index, seen: []const Model.Declaration.Id) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    const lbrace = tree.nodeMainToken(node);
    if (lbrace < 2 or tree.tokenTag(lbrace - 1) != .colon or tree.tokenTag(lbrace - 2) != .identifier) return false;
    const label = tree.tokenSlice(lbrace - 2);
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break") continue;
        const brk: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(brk);
        if (at < first or at > last) continue;
        const data = tree.nodeData(brk).opt_token_and_opt_node;
        const target = data[0].unwrap() orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(target), label)) continue;
        if (try rawValue(c, data[1].unwrap() orelse continue, seen)) return true;
    }
    return false;
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
    _ = c;
    return switch (value) {
        .container => |container| .{ .instance = container },
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
            // A compound assignment is the operator's: `n += s.raw()` computes as `n + s.raw()`.
            .assign_add, .assign_add_wrap, .assign_add_sat, .assign_sub, .assign_sub_wrap, .assign_sub_sat, .assign_mul, .assign_mul_wrap, .assign_mul_sat, .assign_div, .assign_mod, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor => {
                const operands = tree.nodeData(node).node_and_node;
                if (try rawValue(c, operands[0], &.{}) or try rawValue(c, operands[1], &.{})) try c.at(scalar, tree.nodeMainToken(node), operation);
            },
            .negation, .negation_wrap, .bit_not => if (try rawValue(c, tree.nodeData(node).node, &.{})) try c.at(scalar, tree.nodeMainToken(node), operation),
            // std's reads of a value out of bytes or an integer into a scalar's type
            // (`bytesToValue(Index, &b)`, `std.enums.fromInt(Index, v)`) skip its checked
            // construction as the language's casts do.
            .call_one, .call_one_comma, .call, .call_comma => {
                var call_buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&call_buffer, node).?; // unreachable: the tag is a call's
                // Why the call may be one of them, where it is not known to be.
                var maybe: ?Facts.Unknown = null;
                const made = for ([_][]const u8{ "mem.bytesToValue", "mem.bytesAsValue", "mem.bytesAsSlice", "enums.fromInt" }) |path| switch (try stdCall(c, node, path)) {
                    .yes => break true,
                    .no => {},
                    .unknown => |why| maybe = why,
                } else false;
                if ((!made and maybe == null) or call.ast.params.len == 0) continue;
                switch (try perBuild(c, try instanceOf(c, try c.facts.resolve(c.file, call.ast.params[0])))) {
                    .owner => |k| if (k == .scalar) {
                        if (made) {
                            try c.at(scalar, tree.nodeMainToken(node), "an aegis scalar made out of bytes or an integer by std skips its checked construction; use the scalar's checked constructor or justify the boundary");
                        } else if (maybe) |why| try c.unknown(scalar, node, why);
                    },
                    .other => {},
                    .unknown => try c.undecided(scalar, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "the type std makes here does not resolve: it may be an aegis scalar made without its checked construction"),
                }
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
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
            },
            else => {},
        }
    }
}
fn checkCapacity(c: *Context) Context.Error!void {
    if (!try begin(c, capacity)) return;
    const tree = try c.project.syntax(try c.source());
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
        const data = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(data[1])), "adopt") or call.ast.params.len != 2) continue;
        if (try requiredOwner(c, data[0], capacity, data[1]) != .bytes) continue;
        // What was done with the allocation's local before it is adopted.
        if (allocationLocal(c, call.ast.params[0])) |local| switch (try beforeAdoption(c, c.file, local.index, local.read, tree.firstToken(node), 0)) {
            .whole => {},
            .spoiled => |found| {
                try c.at(capacity, tree.nodeMainToken(node), try c.allocator.print("SecretBytes.adopt receives an allocation {s} before it (line {d}): the owner must take the whole allocation alone", .{ found.what, c.project.at(c.file).file.line(tree.tokenStart(tree.nodeMainToken(found.at))) + 1 }));
                continue;
            },
            .unknown => |at| {
                try c.undecided(capacity, tree.tokenStart(tree.nodeMainToken(at)), .unsupported, "what this does with an allocation adopted after it is not known: it may free, change or keep it");
                continue;
            },
        };
        if (try wholeAllocation(c, node, call.ast.params[0])) continue;
        if (tree.fullSlice(call.ast.params[0])) |slice| {
            if (slice.ast.end.unwrap() != null) try c.at(capacity, tree.nodeMainToken(node), "SecretBytes.adopt receives an explicitly bounded slice: full allocator capacity/exclusive ownership must be retained; extent is undecided");
        }
        try c.undecided(capacity, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "slice syntax cannot prove full allocator extent, provenance, alignment or exclusive transfer; runtime wipe/free obligations remain");
    }
}

/// Whether an adoption's `allocation` is a whole byte allocation the adoption takes over alone,
/// so the extent is the allocation's and the alignment a byte's: `a.alloc(u8, n)`, `a.dupe(u8,
/// bytes)` or `a.print(format, args)`, through `try`, a `catch` or `orelse` that does not
/// complete, a local it initializes, an `if` capture of it, what a function of this file returns
/// on every path that gives a value, or a parameter of a private function every call of which
/// passes one. Nothing else may hold it once it is taken: no use of a local follows, and none
/// waits in a `defer` or `errdefer`, which would free or reach memory the owner now holds. Any
/// other shape stays a review site. The owner is unmanaged: the allocator its `deinit` is given
/// is the caller's to keep the one that made the allocation.
fn wholeAllocation(c: *Context, adoption: Ast.Node.Index, allocation: Ast.Node.Index) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    return wholeBytes(c, allocation, null, &.{}, tree.lastToken(adoption), 0);
}

/// A value named as a path: a declaration of the checked file, then members of it (`s.gpa`).
const Path = struct { root: Model.Declaration.Id, chain: []const []const u8 };

fn pathOf(c: *Context, node: Ast.Node.Index) Context.Error!?Path {
    const tree = try c.project.syntax(try c.source());
    return switch (tree.nodeTag(node)) {
        .identifier => .{ .root = Contract.local(c, node) orelse return null, .chain = &.{} },
        .grouped_expression => pathOf(c, tree.nodeData(node).node_and_token[0]),
        .field_access => blk: {
            const data = tree.nodeData(node).node_and_token;
            const base = (try pathOf(c, data[0])) orelse break :blk null;
            break :blk .{ .root = base.root, .chain = try std.mem.concat(c.allocator, []const u8, &.{ base.chain, &.{tree.tokenSlice(data[1])} }) };
        },
        else => null,
    };
}

fn samePaths(a: Path, b: Path) bool {
    if (a.root != b.root or a.chain.len != b.chain.len) return false;
    for (a.chain, b.chain) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// A call a value is read through: into `function`, called by `call`.
const Frame = struct { function: Model.Declaration.Id, call: Ast.Node.Index };

/// `path`, read inside the function the innermost of `frames` calls, as the function the
/// outermost call is in reads it: a parameter is the call's argument there; a declaration
/// outside the called function is the same one. Null for one of the function's own locals.
fn outward(c: *Context, path: Path, frames: []const Frame) Context.Error!?Path {
    var current = path;
    var at = frames.len;
    while (at > 0) {
        at -= 1;
        const frame = frames[at];
        if (parameterPosition(c, frame.function, current.root)) |position| {
            const argument = argumentAt(c, frame.function, frame.call, position) orelse return null;
            const base = (try pathOf(c, argument)) orelse return null;
            current = .{ .root = base.root, .chain = try std.mem.concat(c.allocator, []const u8, &.{ base.chain, current.chain }) };
        } else if (within(c, current.root, frame.function)) return null;
    }
    return current;
}

/// The position of `decl` among the parameters of `function`, if it is one.
fn parameterPosition(c: *Context, function: Model.Declaration.Id, decl: Model.Declaration.Id) ?usize {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    if (model.declarations[@backingInt(decl)].kind != .parameter) return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(function)].node) orelse return null;
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) if (param.name_token == model.declarations[@backingInt(decl)].token) return position;
    return null;
}

/// Whether `decl` is declared inside `function`'s body or among its parameters.
fn within(c: *Context, decl: Model.Declaration.Id, function: Model.Declaration.Id) bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const node = model.declarations[@backingInt(function)].node;
    const whole_fn = model.parentOf(node) orelse node;
    const token = model.declarations[@backingInt(decl)].token;
    return tree.firstToken(whole_fn) <= token and token <= tree.lastToken(whole_fn);
}

/// The argument `call` passes at `function`'s parameter `position`: a method called on a value
/// takes the value first.
fn argumentAt(c: *Context, function: Model.Declaration.Id, call_node: Ast.Node.Index, position: usize) ?Ast.Node.Index {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, call_node) orelse return null;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, model.declarations[@backingInt(function)].node) orelse return null;
    var count: usize = 0;
    var it = proto.iterate(tree);
    while (it.next()) |_| count += 1;
    const method = tree.nodeTag(call.ast.fn_expr) == .field_access and count == call.ast.params.len + 1;
    if (method and position == 0) return tree.nodeData(call.ast.fn_expr).node_and_token[0];
    const at = if (method) position - 1 else position;
    return if (at < call.ast.params.len) call.ast.params[at] else null;
}

/// Whether `node`, read in the function the innermost of `frames` calls, is a whole byte
/// allocation of the allocator `want` names in the function the outermost call is in, held
/// by nothing else after `until` (see `wholeAllocation`).
fn wholeBytes(c: *Context, node: Ast.Node.Index, want: ?Path, frames: []const Frame, until: Ast.TokenIndex, depth: usize) Context.Error!bool {
    if (depth == 16) return false;
    const tree = try c.project.syntax(try c.source());
    const model = &c.project.at(c.file).model;
    switch (Facts.accesses.formOf(tree.nodeTag(node))) {
        .grouped, .tried => return wholeBytes(c, Facts.accesses.carriedFrom(tree, node).?, want, frames, until, depth + 1),
        // The other side does not complete: the value is the operand's.
        .@"catch", .@"orelse" => {
            if (!completesNot(tree, tree.nodeData(node).node_and_node[1])) return false;
            return wholeBytes(c, Facts.accesses.carriedFrom(tree, node).?, want, frames, until, depth + 1);
        },
        // A name: a local's value, a capture's operand or a parameter's argument.
        .leaf => {
            const index = Contract.local(c, node) orelse return false;
            const decl = model.declarations[@backingInt(index)];
            switch (decl.kind) {
                .variable => {
                    if (model.scopes[@backingInt(decl.scope)].kind != .block) return false;
                    const v = tree.fullVarDecl(decl.node) orelse return false;
                    const init = v.ast.init_node.unwrap() orelse return false;
                    if (!heldAlone(c, index, node, until)) return false;
                    return wholeBytes(c, init, want, frames, until, depth + 1);
                },
                // `if (x) |bytes|`: the optional's payload.
                .capture => {
                    const branch = tree.fullIf(decl.node) orelse return false;
                    if (branch.payload_token != decl.token or branch.error_token != null) return false;
                    if (!heldAlone(c, index, node, until)) return false;
                    return wholeBytes(c, branch.ast.cond_expr, want, frames, until, depth + 1);
                },
                .parameter => {
                    // A parameter of a function read through a call: that call's argument.
                    if (frames.len != 0) {
                        const frame = frames[frames.len - 1];
                        const position = parameterPosition(c, frame.function, index) orelse return false;
                        const argument = argumentAt(c, frame.function, frame.call, position) orelse return false;
                        return wholeBytes(c, argument, want, frames[0 .. frames.len - 1], tree.lastToken(frame.call), depth + 1);
                    }
                    return passedWhole(c, index, want, depth);
                },
                else => return false,
            }
        },
        else => {},
    }
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&buffer, node) == null) return false;
    const site = (try Facts.calls.at(c.facts, c.file, node)).?; // unreachable: `node` is a call
    // A call that may be of another function, or of std's allocator that is not known, is no
    // whole allocation shown: the adoption stays a review site.
    const function = switch (try calledFunction(c, c.file, node)) {
        .function => |called| called,
        .unknown => return false,
    };
    // std's allocator by its declarations: a byte allocation, a copy of bytes or printed text.
    // The allocator first, then the element type and length, or the format and its arguments.
    if (site.args == .known and site.args.known.len == 3) {
        const args = site.args.known;
        const made = if (try isStd(c, function, "mem.Allocator.alloc") == .yes or try isStd(c, function, "mem.Allocator.dupe") == .yes)
            try isByte(c, args[1])
        else
            try isStd(c, function, "mem.Allocator.print") == .yes;
        if (made) {
            const expected = want orelse return true;
            const giver = (try pathOf(c, args[0])) orelse return false;
            const read = (try outward(c, giver, frames)) orelse return false;
            return samePaths(read, expected);
        }
    }
    // A function of this file: what it returns on every path that gives a value.
    if (function.file != c.file or model.declarations[@backingInt(function.index)].kind != .function) return false;
    const body_fn = model.parentOf(model.declarations[@backingInt(function.index)].node) orelse return false;
    if (tree.nodeTag(body_fn) != .fn_decl) return false;
    const inner = try std.mem.concat(c.allocator, Frame, &.{ frames, &.{.{ .function = function.index, .call = node }} });
    var gives = false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const ret: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (enclosingFunction(tree, model, ret) != body_fn) continue;
        const value = tree.nodeData(ret).opt_node.unwrap() orelse continue;
        // An error or `null` returned gives no allocation.
        if (try c.facts.literalOf(c.file, value)) |literal| switch (literal) {
            .error_value, .null => continue,
            else => {},
        };
        if (!try wholeBytes(c, value, want, inner, tree.lastToken(ret), depth + 1)) return false;
        gives = true;
    }
    return gives;
}

/// The local an adoption's argument names (through `try` and a grouping), and that reading.
fn allocationLocal(c: *Context, node: Ast.Node.Index) ?struct { index: Model.Declaration.Id, read: Ast.Node.Index } {
    const tree = &c.project.at(c.file).file.tree;
    var current = node;
    while (true) current = switch (tree.nodeTag(current)) {
        .grouped_expression => tree.nodeData(current).node_and_token[0],
        .@"try" => tree.nodeData(current).node,
        .identifier => break,
        else => return null,
    };
    const index = Contract.local(c, current) orelse return null;
    const decl = c.project.at(c.file).model.declarations[@backingInt(index)];
    if (decl.kind != .variable and decl.kind != .capture) return null;
    return .{ .index = index, .read = current };
}

const Before = union(enum) { whole, spoiled: struct { at: Ast.Node.Index, what: []const u8 }, unknown: Ast.Node.Index };

/// The declaration of `function`'s parameter at `position`, in its file.
fn parameterOf(c: *Context, function: Facts.Decl, position: usize) ?Model.Declaration.Id {
    const tree = &c.project.at(function.file).file.tree;
    const model = &c.project.at(function.file).model;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(function.index)].node) orelse return null;
    var it = proto.iterate(tree);
    var at: usize = 0;
    const token = while (it.next()) |param| : (at += 1) {
        if (at == position) break param.name_token orelse return null;
    } else return null;
    for (model.declarations, 0..) |decl, i| if (decl.kind == .parameter and decl.token == token) return @fromBackingInt(@intCast(i));
    return null;
}

/// What each use of the local `index` before `until`, apart from `read`, does with the
/// allocation it holds: an element read or written, its length, a comparison, a builtin that
/// copies into or out of it, or its address compared, leave it whole; a free, a write of the
/// slice itself (`buf = ...`, `buf.len = 1`, `buf.ptr += 1`), or a copy of it or its address
/// kept elsewhere (stored, put in a local, a literal or another adoption) spoil it. A function
/// it is handed to is read the same way in its parameter, through `depth` calls, and leaves
/// it whole where it does and gives back no pointer. Any other use is not known. Deferred uses
/// are left to `heldAlone`. `file` is the one the local is in.
fn beforeAdoption(c: *Context, file: Project.FileId, index: Model.Declaration.Id, read: Ast.Node.Index, until: Ast.TokenIndex, depth: u8) Context.Error!Before {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const use: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (use == read or tree.nodeMainToken(use) >= until) continue;
        const ref = model.reference(use) orelse continue;
        if (ref.declaration != index) continue;
        // Deferred code runs at the scope's end: `heldAlone` reads it.
        var deferred = false;
        var up = model.parentOf(use);
        while (up) |parent| : (up = model.parentOf(parent)) switch (tree.nodeTag(parent)) {
            .@"defer", .@"errdefer" => deferred = true,
            else => {},
        };
        if (deferred) continue;
        const found = try allocationUse(c, file, use, depth);
        if (found != .whole) return found;
    }
    return .whole;
}

fn allocationUse(c: *Context, file: Project.FileId, use: Ast.Node.Index, depth: u8) Context.Error!Before {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    // `view` is what holds the allocation's memory: the local, a slice of it, its `.ptr`.
    var view = use;
    while (model.parentOf(view)) |parent| {
        switch (tree.nodeTag(parent)) {
            .grouped_expression, .@"try" => view = parent,
            .slice, .slice_open, .slice_sentinel => {
                if (tree.fullSlice(parent).?.ast.sliced != view) return .whole; // unreachable: the tag is a slice's
                view = parent;
            },
            .field_access => {
                const name = tree.tokenSlice(tree.nodeData(parent).node_and_token[1]);
                const written = if (model.parentOf(parent)) |above| assigning(tree.nodeTag(above)) and tree.nodeData(above).node_and_node[0] == parent else false;
                if (written) return .{ .spoiled = .{ .at = parent, .what = "changed" } };
                if (std.mem.eql(u8, name, "len")) return .whole;
                if (!std.mem.eql(u8, name, "ptr")) return .{ .unknown = parent };
                view = parent;
            },
            // An element, read or written.
            .array_access => return .whole,
            else => break,
        }
    }
    const parent = model.parentOf(view) orelse return .{ .unknown = view };
    const tag = tree.nodeTag(parent);
    if (assigning(tag)) {
        const sides = tree.nodeData(parent).node_and_node;
        return if (sides[0] == view) .{ .spoiled = .{ .at = parent, .what = "changed" } } else .{ .spoiled = .{ .at = parent, .what = "kept elsewhere" } };
    }
    switch (tag) {
        // A comparison, or a pass that leaves without it.
        .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .@"return" => return .whole,
        else => {},
    }
    if (tree.fullVarDecl(parent) != null) return .{ .spoiled = .{ .at = parent, .what = "kept elsewhere" } };
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, parent) != null or tree.fullArrayInit(&buffer, parent) != null) return .{ .spoiled = .{ .at = parent, .what = "kept elsewhere" } };
    switch (tag) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(parent));
            const kept = [_][]const u8{ "@memset", "@memcpy", "@memmove", "@sizeOf", "@TypeOf" };
            for (kept) |each| if (std.mem.eql(u8, name, each)) return .whole;
            // Its address as a number: what is done with the number, as with the memory
            // (`where = @intFromPtr(buf.ptr)` keeps it; a comparison does not).
            if (std.mem.eql(u8, name, "@intFromPtr")) return allocationUse(c, file, parent, depth);
            return .{ .unknown = parent };
        },
        else => {},
    }
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, parent) orelse return .{ .unknown = parent };
    if (call.ast.fn_expr == view) return .{ .unknown = parent };
    const function = switch (try calledFunction(c, file, parent)) {
        .function => |called| called,
        .unknown => return .{ .unknown = parent },
    };
    // Given back to its allocator, or to another owner.
    const frees = [_][]const u8{ "mem.Allocator.free", "mem.Allocator.destroy", "mem.Allocator.realloc", "mem.Allocator.resize", "mem.Allocator.remap" };
    for (frees) |path| switch (try isStd(c, function, path)) {
        .yes => return .{ .spoiled = .{ .at = parent, .what = "freed or resized" } },
        .no => {},
        .unknown => return .{ .unknown = parent },
    };
    if (file == c.file and tree.nodeTag(call.ast.fn_expr) == .field_access) {
        const data = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(data[1])), "adopt") and try requiredOwner(c, data[0], capacity, data[1]) == .bytes) return .{ .spoiled = .{ .at = parent, .what = "adopted by another owner" } };
    }
    // A function it is handed to: what it does with its parameter there. One that frees or
    // keeps it spoils it; one that leaves it whole and gives back no pointer hands nothing on.
    if (depth == 4) return .{ .unknown = parent };
    const receiver: usize = if (tree.nodeTag(call.ast.fn_expr) == .field_access) switch (try c.facts.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
        .instance => 1,
        .pointer => |p| @intFromBool(p.* == .instance),
        else => 0,
    } else 0;
    const position = std.mem.findScalar(Ast.Node.Index, call.ast.params, view) orelse return .{ .unknown = parent };
    const parameter = parameterOf(c, function, position + receiver) orelse return .{ .unknown = parent };
    const body = &c.project.at(function.file).file.tree;
    const scope = c.project.at(function.file).model.parentOf(c.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return .{ .unknown = parent };
    switch (try beforeAdoption(c, function.file, parameter, .root, body.lastToken(scope) + 1, depth + 1)) {
        .whole => return if (scalarShaped(c, try c.facts.resolve(file, parent))) .whole else .{ .unknown = parent },
        .spoiled => |found| return .{ .spoiled = .{ .at = parent, .what = found.what } },
        .unknown => return .{ .unknown = parent },
    }
}

/// Whether `node` never completes with a value: `return`, `unreachable`, a `break` or
/// `continue`.
fn completesNot(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .@"return", .unreachable_literal, .@"break", .@"continue" => true,
        else => false,
    };
}

/// Whether the type written at `node` is `u8`, by what it resolves to.
fn isByte(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const value = try c.facts.resolve(c.file, node);
    return value == .primitive and std.mem.eql(u8, value.primitive, "u8");
}

/// The `fn_decl` whose body holds `node`, nearest first.
fn enclosingFunction(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Ast.Node.Index {
    var up = model.parentOf(node);
    while (up) |parent| : (up = model.parentOf(parent)) {
        if (tree.nodeTag(parent) == .fn_decl) return parent;
    }
    return null;
}

/// Whether the local `index` is named, apart from at `read`, only before `until` and never in
/// deferred code: what it holds is the reader's alone from there.
fn heldAlone(c: *Context, index: Model.Declaration.Id, read: Ast.Node.Index, until: Ast.TokenIndex) bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (candidate == read) continue;
        const ref = model.reference(candidate) orelse continue;
        if (ref.declaration != index) continue;
        if (tree.nodeMainToken(candidate) > until) return false;
        var up = model.node_parents[i];
        while (up) |parent| : (up = model.parentOf(parent)) {
            switch (tree.nodeTag(parent)) {
                .@"defer", .@"errdefer" => return false,
                else => {},
            }
        }
    }
    return true;
}

/// Whether every call of the function whose parameter `index` is passes a whole allocation
/// there, of the allocator `want` names in the function, read at the call: the function is
/// private to this file and named only as the callee of calls.
fn passedWhole(c: *Context, index: Model.Declaration.Id, want: ?Path, depth: usize) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    const model = &c.project.at(c.file).model;
    const function: Model.Declaration.Id = for (model.declarations, 0..) |d, i| {
        if (d.kind == .function and parameterPosition(c, @fromBackingInt(@intCast(i)), index) != null) break @fromBackingInt(@intCast(i));
    } else return false;
    const record = model.declarations[@backingInt(function)];
    if (record.public or record.exported) return false;
    // A method's calls name it as a member, which a declaration's references do not show.
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .field_access) continue;
        const member: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (std.mem.eql(u8, tree.tokenSlice(tree.nodeData(member).node_and_token[1]), record.name)) return false;
    }
    const position = parameterPosition(c, function, index).?; // unreachable: the parameter was found in this function
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const use: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeMainToken(use) == record.token) continue;
        const ref = model.reference(use) orelse continue;
        if (ref.declaration != function) continue;
        const parent = model.node_parents[i] orelse return false;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, parent) orelse return false;
        if (call.ast.fn_expr != use) return false;
        const frame: Frame = .{ .function = function, .call = parent };
        const read: ?Path = if (want) |expected| (try outward(c, expected, &.{frame})) orelse return false else null;
        const argument = argumentAt(c, function, parent, position) orelse return false;
        if (!try wholeBytes(c, argument, read, &.{}, tree.lastToken(parent), depth + 1)) return false;
    }
    return true;
}
