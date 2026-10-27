//! Optional explicitly adopted published-type obligations. No security or lifetime proof.
const std = @import("std");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const Context = @import("RuleContext.zig");
const Contract = @import("AegisContract.zig");
const Ids = @import("AegisRules.zig");
const Danger = @import("Danger.zig");
const Shapes = @import("DangerShapes.zig");
const Flows = @import("DangerFlow.zig");
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
/// The danger rules: each finds where a danger exists and aegis's type is the answer.
pub const danger = [_]Rule{ shared_state, secrets, untrusted_input, integers, units, bounded_work, contracts, lifetimes, ownership, identity, state_machines, diagnostics, unsafe_set, cancellation, lock_order };
pub const rules = [_]Context.Rule{
    .{ .definition = .{ .id = access, .name = "A001", .group = .family_policy, .purpose = "secret disclosure or shared-state access without a live capability", .version = 2, .exception = .aegis }, .check = checkAccess },
    .{ .definition = .{ .id = copies, .name = "A002", .group = .family_policy, .purpose = "duplicated secret owner or lock capability; borrowed storage escapes", .version = 2, .exception = .aegis }, .check = checkCopies },
    .{ .definition = .{ .id = cleanup, .name = "A003", .group = .family_policy, .purpose = "missing owner cleanup or use after cleanup/transfer on a supported local path", .version = 2, .exception = .aegis }, .check = checkCleanup },
    .{ .definition = .{ .id = scalar, .name = "A004", .group = .family_policy, .purpose = "domain/unit or all-build integer checks bypassed by raw arithmetic/casts", .version = 2, .exception = .aegis }, .check = checkScalar },
    .{ .definition = .{ .id = capacity, .name = "A005", .group = .family_policy, .purpose = "SecretBytes adoption truncates wipe capacity or lacks proven allocation ownership", .version = 2, .exception = .aegis }, .check = checkCapacity },
    .{ .definition = .{ .id = recursion, .name = "A006", .group = .family_policy, .purpose = "recursion reachable from untrusted input without a depth bound", .version = 1, .exception = .aegis }, .check = checkRecursion },
    .{ .definition = .{ .id = shared_state, .name = "A007", .group = .family_policy, .purpose = "shared state outside aegis's guards", .exception = .aegis }, .check = checkSharedState },
    .{ .definition = .{ .id = secrets, .name = "A008", .group = .family_policy, .purpose = "secret material outside aegis's Secret and Choice", .exception = .aegis }, .check = checkSecrets },
    .{ .definition = .{ .id = untrusted_input, .name = "A009", .group = .family_policy, .purpose = "input used before a parser refines it", .exception = .aegis }, .check = checkInput },
    .{ .definition = .{ .id = integers, .name = "A010", .group = .family_policy, .purpose = "integer conversion or arithmetic on input that a peer can make fail", .exception = .aegis }, .check = checkIntegers },
    .{ .definition = .{ .id = units, .name = "A011", .group = .family_policy, .purpose = "time crossing to std as a raw integer", .exception = .aegis }, .check = checkUnits },
    .{ .definition = .{ .id = bounded_work, .name = "A012", .group = .family_policy, .purpose = "work sized by input without a stated limit", .exception = .aegis }, .check = checkBoundedWork },
    .{ .definition = .{ .id = contracts, .name = "A013", .group = .family_policy, .purpose = "contract that is undefined behaviour when false in a release build", .exception = .aegis }, .check = checkContracts },
    .{ .definition = .{ .id = lifetimes, .name = "A014", .group = .family_policy, .purpose = "pointer that outlives what it points into", .exception = .aegis }, .check = checkLifetimes },
    .{ .definition = .{ .id = ownership, .name = "A015", .group = .family_policy, .purpose = "std resource held or returned without its one owner", .exception = .aegis }, .check = checkOwnership },
    .{ .definition = .{ .id = identity, .name = "A016", .group = .family_policy, .purpose = "identifying integers of one type that one may pass for another", .exception = .aegis }, .check = checkIdentity },
    .{ .definition = .{ .id = state_machines, .name = "A017", .group = .family_policy, .purpose = "state machine kept by hand", .exception = .aegis }, .check = checkStateMachines },
    .{ .definition = .{ .id = diagnostics, .name = "A018", .group = .family_policy, .purpose = "internal text written to a peer", .exception = .aegis }, .check = checkDiagnostics },
    .{ .definition = .{ .id = unsafe_set, .name = "A019", .group = .family_policy, .purpose = "operation Zig leaves unchecked", .exception = .aegis }, .check = checkUnsafeSet },
    .{ .definition = .{ .id = cancellation, .name = "A020", .group = .family_policy, .purpose = "loop on input or without bound that cannot be canceled", .exception = .aegis }, .check = checkCancellation },
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
    try Shapes.undefinedReads(c, unsafe_set);
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
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (made_by_constructor.len != 0) try checkLiteral(c, tree, node, made_by_constructor);
        if (tag != .field_access) continue;
        const data = tree.nodeData(node).node_and_token;
        const name = try Model.identifier(c.allocator, tree.tokenSlice(data[1]));
        if (!backingName(name)) continue;
        if (try typeValue(c, data[0])) continue;
        if (try refuted(c, node, name)) continue;
        const k = (try requiredOwner(c, data[0], access, data[1])) orelse continue;
        const is_backing = backing(k, name);
        if (is_backing) try c.at(access, data[1], "published aegis backing field bypasses exposure/guard/ownership contract; review this access");
    }
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
/// Whether a literal could be a value of `container`: every field it names is one of the
/// container's, and it names every field that has no default.
fn namesFields(c: *Context, tree: *const Ast, literal: Ast.full.StructInit, container: Facts.Container) Context.Error!bool {
    const model = &c.project.models[container.file.raw()];
    const own = &c.project.files[container.file.raw()].tree;
    for (literal.ast.fields) |value| {
        const name = try Model.identifier(c.allocator, tree.tokenSlice(tree.firstToken(value) - 2));
        const field = c.facts.member(container, name) orelse return false;
        if (model.declarations[field.index].kind != .field) return false;
    }
    for (model.declarations) |decl| {
        if (decl.kind != .field or decl.scope != container.scope) continue;
        if (own.fullContainerField(decl.node).?.ast.value_expr != .none) continue;
        for (literal.ast.fields) |value| {
            if (std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(tree.firstToken(value) - 2)), decl.name)) break;
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
        const model = &c.project.models[file.raw()];
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
    if (tree.nodeTag(node) != .identifier) return false;
    const model = &c.project.models[c.file.raw()];
    const index = (model.reference(node) orelse return false).declaration orelse return false;
    const decl = model.declarations[index];
    const declared = if (decl.kind == .parameter) decl.node else if (tree.fullVarDecl(decl.node)) |v| v.ast.type_node.unwrap() orelse return false else return false;
    return tree.nodeTag(declared) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(declared)), "type");
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
    const model = &c.project.models[c.file.raw()];
    // What the program reads of `x.name`.
    var member: ?[]const u8 = null;
    // Whether the program uses `x.name` as a truth value, a number or an operand of a comparison.
    var operand = false;
    // Whether the program calls `x.name(...)`: a method, or a field that holds a function.
    var called = false;
    if (model.node_parents[@backingInt(field)]) |parent| { // safe: an AST node index reads its own parent table
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
        if (tree.fullVarDecl(model.declarations[index].node)) |v| if (v.ast.init_node.unwrap()) |init| {
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
        const record = c.project.models[decl.file.raw()].declarations[decl.index];
        if (record.kind != .field) continue;
        any = true;
        if (literal) |value| {
            const lacks = for (value.ast.fields) |init| {
                const label = try Model.identifier(c.allocator, tree.tokenSlice(tree.firstToken(init) - 2));
                const named = c.facts.member(container, label) orelse break true;
                if (c.project.models[named.file.raw()].declarations[named.index].kind != .field) break true;
            } else false;
            if (lacks) continue;
        }
        const written = &c.project.files[decl.file.raw()].tree;
        const type_expr = written.fullContainerField(record.node).?.ast.type_expr.unwrap() orelse return false;
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
    const model = &c.project.models[container.file.raw()];
    const tree = &c.project.files[container.file.raw()].tree;
    const node = model.scopes[container.scope].node;
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
            const model = &c.project.models[function.file.raw()];
            const tree = &c.project.files[function.file.raw()].tree;
            const record = model.declarations[function.index];
            const whole = if (tree.nodeTag(record.node) == .fn_decl) record.node else model.node_parents[@backingInt(record.node)] orelse return null; // safe: an AST node index reads its own parent table
            for (model.scopes, 0..) |scope, i| {
                if (scope.kind != .container) continue;
                var at = scope.parent;
                while (at) |p| : (at = model.scopes[p].parent) {
                    if (model.scopes[p].kind == .container) break;
                    if (model.scopes[p].kind == .function) {
                        if (model.scopes[p].node == whole or model.scopes[p].node == record.node) return .{ .file = function.file, .scope = @intCast(i) };
                        break;
                    }
                }
            }
            return null;
        },
    }
}

/// Whether `name` is a backing field of a published type of kind `k`.
fn backing(k: Contract.Kind, name: []const u8) bool {
    return switch (k) {
        .secret => std.mem.eql(u8, name, "material"),
        .bytes => std.mem.eql(u8, name, "allocation") or std.mem.eql(u8, name, "used_len") or std.mem.eql(u8, name, "gpa"),
        // The guarded value and the lock state of every guarded owner: a spin flag, a
        // blocking mutex, a reader-writer lock and its admission count.
        // An ordered owner's base lock too.
        .guarded => std.mem.eql(u8, name, "data") or std.mem.eql(u8, name, "lock") or std.mem.eql(u8, name, "mutex") or std.mem.eql(u8, name, "state") or std.mem.eql(u8, name, "admitted") or std.mem.eql(u8, name, "base"),
        // A guard's owner; an ordered guard's base guard.
        .guard => std.mem.eql(u8, name, "owner") or std.mem.eql(u8, name, "base"),
        // A value initialized once: its publication state, its election lock and waiters,
        // and the value itself before the state says it is there.
        .once => std.mem.eql(u8, name, "state") or std.mem.eql(u8, name, "mutex") or std.mem.eql(u8, name, "changed") or std.mem.eql(u8, name, "data"),
        // A value one logical task owns: the value and the identity that is checked.
        .confined => std.mem.eql(u8, name, "data") or std.mem.eql(u8, name, "owner"),
        else => for (backingFields(k)) |field| {
            if (std.mem.eql(u8, name, field)) break true;
        } else false,
    };
}

/// The private state of the published types after the guards: what each type's source keeps
/// behind its operations (the initialized prefix and its cursors, a budget's charge, an owner's
/// payload and witness, a loan's copy, a staged payload, a machine's state, a scope's record,
/// the checked pointer, the unparsed value, the decision bit).
fn backingFields(k: Contract.Kind) []const []const u8 {
    return switch (k) {
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

fn backingName(name: []const u8) bool {
    for ([_][]const u8{ "material", "allocation", "used_len", "gpa", "data", "lock", "mutex", "state", "admitted", "owner", "changed", "base" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    for (std.enums.values(Contract.Kind)) |k| for (backingFields(k)) |field| if (std.mem.eql(u8, name, field)) return true;
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
        .reservation => &.{ "release", "consume", "moveInto" },
        .owned => &.{ "deinit", "take", "moveInto" },
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
    if (try Contract.owner(c, node)) |k| return k;
    const value = try c.facts.resolve(c.file, node);
    // A type chosen at compile time is one type per build: an operation on it is the
    // owner's in the builds that choose the owner. Cleanup is owed along the paths of those
    // builds, which are every path unless the function branches on a comptime condition
    // (`if (wrapped) owner.deinit();`); then A003 leaves a choice that disagrees undecided.
    const read = if (rule != cleanup or !try c.facts.branchesOnCondition(c.file, node)) try perBuild(c, value) else try typed(c, value, 0);
    switch (read) {
        .owner => |k| return k,
        .other => return null,
        .unknown => {
            const tree = try c.project.syntax(try c.source());
            if (try noLibraryCall(c, tree, node)) return null;
            try c.undecided(rule, tree.tokenStart(token), .unresolved, "candidate receiver/value has no resolved operation contract");
            return null;
        },
    }
}
/// Whether `node` is a call `x.name(...)` that no function the library declares can be, by
/// what Zig allows (`RuleContext.accepts`): `access.read([]const u8)` gives a type where every
/// aegis `read` takes an `Io` or nothing. Whatever `x` is, the result is then no aegis owner
/// an aegis operation gave.
fn noLibraryCall(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!bool {
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const name = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]));
    // A receiver held at run time calls a method, never a namespace's function.
    const value = try c.facts.runtime(c.file, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
    const found = try c.facts.publication(Contract.library);
    for (found.files) |file| {
        const model = &c.project.models[file.raw()];
        for (model.declarations, 0..) |decl, i| {
            if (!std.mem.eql(u8, decl.name, name) or model.scopes[decl.scope].kind != .container) continue;
            const candidate: Facts.Decl = .{ .file = file, .index = @intCast(i) };
            // A constant or a field of no function's type is no callee; one that may hold a
            // function (a pointer, or a type not known) may be.
            switch (try c.facts.declaration(candidate)) {
                .function => {},
                .unknown, .pointer, .alternatives => return false,
                else => continue,
            }
            if (try c.accepts(candidate, call, 1) or (!value and try c.accepts(candidate, call, 0))) return false;
        }
    }
    return true;
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
    const scopes = c.project.models[container.file.raw()].scopes; // safe: a resolved container's file indexes the frozen model table.
    var scope = scopes[container.scope].parent;
    while (scope) |s| : (scope = scopes[s].parent) {
        for (found.entries) |entry| if (entry.target == .container and entry.target.container.file.eql(container.file) and entry.target.container.scope == s) return @fromBackingInt(@intCast(entry.role));
    }
    return null;
}
/// The name a container is declared under (`pub const Guard = struct { ... }`), if any.
fn containerName(c: *Context, container: Facts.Container) ?[]const u8 {
    const model = &c.project.models[container.file.raw()];
    const tree = &c.project.files[container.file.raw()].tree;
    const node = model.scopes[container.scope].node;
    if (node == .root) return null;
    const parent = model.node_parents[@backingInt(node)] orelse return null; // safe: an AST node index reads its own parent table
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
            .std_internal, .absent => .other,
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
            break :blk .other;
        },
        else => .other,
    };
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
    if (!try c.facts.mayCopy(try Model.identifier(c.allocator, tree.tokenSlice(name_token)))) return;
    const decl = (try c.facts.definition(c.file, call.ast.fn_expr)) orelse return;
    const function = (try c.facts.origin(decl)) orelse return;
    const made = try c.facts.parameterCopies(function);
    if (made.len == 0) return;
    const written = &c.project.files[function.file.raw()].tree;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = written.fullFnProto(&proto_buffer, c.project.models[function.file.raw()].declarations[function.index].node) orelse return;
    // Which parameters take a type: a binding of one is a type the call writes.
    var types: [64]bool = @splat(false);
    var values: [64]bool = @splat(false);
    var count: usize = 0;
    var it = proto.iterate(written);
    while (it.next()) |param| : (count += 1) {
        if (count == types.len) return;
        types[count] = if (param.type_expr) |t| written.nodeTag(t) == .identifier and std.mem.eql(u8, written.tokenSlice(written.nodeMainToken(t)), "type") else false;
        values[count] = param.anytype_ellipsis3 != null;
    }
    const receiver: usize = if (tree.nodeTag(call.ast.fn_expr) == .field_access and count == call.ast.params.len + 1) 1 else 0;
    for (made) |copy| {
        if ((copy.kind == .made) != (rule == cleanup)) continue;
        if (copy.kind == .made and !try acquiring(c, copy.site)) continue;
        if (copy.position < receiver or copy.position - receiver >= call.ast.params.len) continue;
        if (!types[copy.position] and !values[copy.position]) continue;
        const argument = call.ast.params[copy.position - receiver];
        // A parameter of a generic this call is in, passed on: decided where that is bound.
        if (c.facts.fromParameter(c.file, argument)) continue;
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
        // A pointer type: its copies are aliases, which A002 leaves out.
        if (pointerShaped(value)) continue;
        // A type argument stands for its values.
        const bound = switch (value) {
            .container => |container| Facts.Value{ .instance = container },
            else => value,
        };
        if (copy.kind == .made) {
            const site = &c.project.files[copy.site.file.raw()];
            const line = site.line(site.tree.tokenStart(site.tree.firstToken(copy.site.node))) + 1;
            switch (try perBuild(c, bound)) {
                .owner => |k| if (releases(k) != null) try c.undecided(cleanup, tree.tokenStart(tree.nodeMainToken(node)), .unsupported, try c.allocator.print("this binding makes an owner of what {s}:{d} acquires by the generic's type parameter; its cleanup is not walked per binding", .{ c.project.inputs[copy.site.file.raw()].name, line })),
                .other => {},
                .unknown => if (!bindingTyped(bound)) try c.undecided(cleanup, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a generic that acquires by its type parameter is bound to a type that does not resolve"),
            }
            continue;
        }
        switch (try copied(c, bound, 0)) {
            .owner => |k| if (copiedOwner(k)) {
                const site = &c.project.files[copy.site.file.raw()];
                const detail = try c.allocator.print("this binding makes a recognized owner of a generic's parameter, which {s}:{d} copies; a duplicated owner requires explicit transfer", .{ c.project.inputs[copy.site.file.raw()].name, site.line(site.tree.tokenStart(site.tree.firstToken(copy.site.node))) + 1 });
                try c.at(copies, tree.nodeMainToken(node), detail);
                return;
            },
            .other => {},
            .unknown => if (!bindingTyped(bound)) try c.undecided(copies, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a generic that copies its parameter is bound to a type that does not resolve"),
        }
    }
}

fn checkCopies(c: *Context) Context.Error!void {
    if (!try begin(c, copies)) return;
    const tree = try c.project.syntax(try c.source());
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        try checkBinding(c, tree, node, copies);
        if (tree.fullVarDecl(node)) |v| {
            const init = v.ast.init_node.unwrap() orelse continue;
            if (tree.nodeTag(init) != .identifier) continue;
            // `undefined`, `true`, `false` and `null` are values, not references to an owner.
            if (c.project.models[c.file.raw()].reference(init) == null) continue; // safe: the checked source handle indexes this frozen model.
            // A value of a generic's parameter: each binding's copy, checked at the binding.
            if (c.facts.parameterValue(c.file, init)) continue;
            // A `comptime` parameter's value, known as the program compiles: it holds nothing at
            // run time.
            if (c.facts.comptimeParameter(c.file, init)) continue;
            // Plain data, as the copy or its source is declared, holds no owner: the copy is decided.
            if (v.ast.type_node.unwrap()) |t| if (try plainType(c, c.file, t, 0)) continue;
            if (try plainValue(c, c.file, init, 0)) continue;
            // A copied pointer is an alias, which this rule leaves out, whatever it points at.
            if (pointerShaped(try c.facts.resolve(c.file, init))) continue;
            const k = (try requiredOwner(c, init, copies, tree.nodeMainToken(init))) orelse continue;
            if (copiedOwner(k)) {
                // An owner itself, resolved so or written so where it comes from.
                if (try c.facts.resolve(c.file, init) != .instance and !try ownedValue(c, init, 0)) continue;
                // A local nothing reads after the copy, deferred code included, is moved, not
                // duplicated: `var guard = free;` out of an `if` capture.
                if (movable(k) and try moved(c, node, init)) continue;
                try c.at(copies, tree.nodeMainToken(node), "copy of a recognized live owner/capability requires explicit transfer; lifetime and publication are undecided");
            }
        }
        if (tag == .@"return") {
            const expr = tree.nodeData(node).opt_node.unwrap() orelse continue;
            if (try exposure(c, expr)) try c.at(copies, tree.nodeMainToken(node), "returned secret/guard borrow can outlive its capability; caller lifetime is undecided");
        }
    }
}
/// Whether an owner of kind `k` may move by assignment: no erasure owed to the bytes left
/// behind (secrets), no address an owner or its borrowers keep (guarded values, a budget its
/// reservations point at, an owner bound to its address in Debug).
fn movable(k: Contract.Kind) bool {
    return switch (k) {
        .guard, .shared, .reservation, .buffer, .slots, .table, .machine, .must_use, .stage, .issuer, .atomic, .context => true,
        else => false,
    };
}

/// Whether `source`, a local or a capture of the function, is never referenced after the
/// declaration `copy` (in a `defer` or `errdefer` anywhere, whose code runs later), and no loop
/// runs the copy again without declaring the source again.
fn moved(c: *Context, copy: Ast.Node.Index, source: Ast.Node.Index) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    const model = &c.project.models[c.file.raw()];
    const index = Contract.local(c, source) orelse return false;
    const decl = model.declarations[index];
    if (decl.kind != .variable and decl.kind != .capture) return false;
    if (decl.kind == .variable and model.scopes[decl.scope].kind != .block) return false;
    const at = tree.lastToken(copy);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (candidate == source) continue;
        const ref = model.reference(candidate) orelse continue;
        if (ref.declaration != index) continue;
        if (tree.nodeMainToken(candidate) > at) return false;
        var up = model.node_parents[i];
        while (up) |parent| : (up = model.node_parents[@backingInt(parent)]) { // safe: an AST node index reads its own parent table
            switch (tree.nodeTag(parent)) {
                .@"defer", .@"errdefer" => return false,
                else => {},
            }
        }
    }
    // A loop between the source's declaration and the copy runs the copy again.
    var up = model.node_parents[@backingInt(copy)]; // safe: an AST node index reads its own parent table
    while (up) |parent| : (up = model.node_parents[@backingInt(parent)]) { // safe: an AST node index reads its own parent table
        if (tree.firstToken(parent) <= decl.token and decl.token <= tree.lastToken(parent)) break;
        if (tree.fullWhile(parent) != null or tree.fullFor(parent) != null) return false;
    }
    return true;
}

/// Whether a type expression is plain data: a primitive type (`usize`, `bool`, `type`), or an array,
/// slice, pointer, optional or error union of plain data. No aegis owner or capability is such a value.
fn plainType(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: usize) Context.Error!bool {
    if (depth == 64) return false;
    const tree = &c.project.files[file.raw()].tree; // safe: the file handle indexes the frozen project table.
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
                const field = tree.fullContainerField(member) orelse continue;
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
    const tree = &c.project.files[file.raw()].tree; // safe: the file handle indexes the frozen project table.
    const model = &c.project.models[file.raw()]; // safe: the file handle indexes the frozen project table.
    switch (tree.nodeTag(node)) {
        .number_literal, .char_literal, .string_literal => return true,
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
            const decl = model.declarations[index];
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
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, node).?;
            const decl = (try c.facts.definition(file, call.ast.fn_expr)) orelse return false;
            const origin = (try c.facts.origin(decl)) orelse return false;
            const record = c.project.models[origin.file.raw()].declarations[origin.index]; // safe: the origin indexes its own frozen model.
            if (record.kind != .function) return false;
            const written = &c.project.files[origin.file.raw()].tree; // safe: the origin indexes the frozen project table.
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
    const tree = &c.project.files[file.raw()].tree; // safe: the file handle indexes the frozen project table.
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
    const decl = c.project.models[c.file.raw()].declarations[index];
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
    const model = &c.project.models[c.file.raw()];
    for (0..tree.nodes.len) |i| try checkBinding(c, tree, @fromBackingInt(@intCast(i)), cleanup);
    for (model.declarations) |decl| {
        if (decl.kind != .variable or model.scopes[decl.scope].kind != .block) continue;
        const v = tree.fullVarDecl(decl.node) orelse continue;
        const init = v.ast.init_node.unwrap() orelse continue;
        // Only actual acquisition expressions, never an owner alias or type alias: an owner's
        // constructor, a guard's acquisition, or a function of the program's own that returns
        // an owner. One that fails holds nothing: `try` and `catch` leave the acquisition itself.
        var call_buffer: [1]Ast.Node.Index = undefined;
        const acquisition = switch (tree.nodeTag(init)) {
            .@"try" => tree.nodeData(init).node,
            .@"catch", .@"orelse" => tree.nodeData(init).node_and_node[0],
            else => init,
        };
        const acquired = tree.fullCall(&call_buffer, acquisition) orelse continue;
        // By a function of the generic's type parameter: each binding's, checked at the binding.
        if (c.facts.madeByParameter(c.file, init) != null) continue;
        const named = tree.nodeTag(acquired.ast.fn_expr) == .field_access and named: {
            const operation = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(acquired.ast.fn_expr).node_and_token[1]));
            break :named std.mem.eql(u8, operation, "init") or std.mem.eql(u8, operation, "adopt") or Contract.acquisition(operation);
        };
        if (!named and !try givesOwner(c, acquisition, acquired.ast.fn_expr)) continue;
        if (try unlisted(c, acquisition)) continue;
        const k = (try requiredOwner(c, acquisition, cleanup, tree.nodeMainToken(acquired.ast.fn_expr))) orelse continue;
        if (releases(k) == null) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, model.scopes[decl.scope].node) orelse continue;
        const at = for (statements, 0..) |stmt, i| {
            if (stmt == decl.node) break i + 1;
        } else continue;
        const flow: Flow = .{ .c = c, .tree = tree, .model = model, .token = decl.token, .kind = k, .scope = model.scopes[decl.scope].node };
        switch (try flow.walk(statements[at..], .live)) {
            .paths => |paths| if (paths.falls == .live) try c.at(cleanup, decl.token, "recognized local acquisition reaches block end without cleanup; review ownership obligation"),
            .split, .uncertain => try c.undecided(cleanup, tree.tokenStart(decl.token), .unsupported, "cleanup/error exits/transfers/aliases require unsupported flow facts; no leak claimed"),
        }
    }
}

/// Whether the local declared at `site` is initialised by an acquisition: an owner's
/// constructor or an operation that gives one by its name.
fn acquiring(c: *Context, site: Facts.Key) Context.Error!bool {
    const tree = &c.project.files[site.file.raw()].tree;
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

/// Whether `call` gives a value of a type the library declares and the contract does not list
/// (a guard's `Handoff`), a guard aside: the contract names every type that carries an
/// obligation, so such a result owes no release here.
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
    return c.inLibrary(Contract.library, container.file);
}

/// Whether `call` gives an owner itself, not a pointer to one: an operation of a published type
/// whose result is a new owner by value (a budget's reservation, a shared value's handle, an
/// opened scope), or a function of the program's own that returns one held, the caller's to
/// release (Flow's `return`).
fn givesOwner(c: *Context, call: Ast.Node.Index, callee: Ast.Node.Index) Context.Error!bool {
    const decl = (try c.facts.definition(c.file, callee)) orelse return false;
    const function = (try c.facts.origin(decl)) orelse return false;
    if (c.project.models[function.file.raw()].declarations[function.index].kind != .function) return false;
    const result = switch (try c.facts.resolve(c.file, call)) {
        .error_union => |payload| payload.*,
        else => |value| value,
    };
    return result == .instance;
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
        flag: u32,
        /// The state past the `if` while the flag is false, and while it is true.
        when: [2]State,
    };
    const Known = struct { flag: u32, value: bool };
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
                if (try f.reacquired(stmt)) {
                    state = .live;
                    continue;
                }
                if (try f.uses(stmt) != .none) return .uncertain;
            }
            if (state == .live and !f.aggregate and !f.pointer) if (try f.movedInto(stmt)) |aggregate| {
                f.token = aggregate;
                f.aggregate = true;
                continue;
            };
            // `errdefer owner.deinit()`: the owner is released on the error exits that follow.
            if (f.tree.nodeTag(stmt) == .@"errdefer" and state == .live and !f.aggregate and try f.releasesIn(f.tree.nodeData(stmt).node)) {
                f.errdeferred = true;
                continue;
            }
            if (try f.handedOff(stmt)) {
                if (state != .live) try f.c.at(cleanup, f.tree.nodeMainToken(stmt), "same local capability is handed off after its cleanup or transfer on this straight-line path");
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
                state = .released;
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
            if (state == .released and try f.reacquired(stmt)) {
                state = .live;
                continue;
            }
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
        var falls: [2]?State = undefined;
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
                if (f.mine(value) or try f.carried(value)) return ends;
            },
            .unreachable_literal => return ends,
            else => {},
        }
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
    fn correlated(f: Flow, stmt: Ast.Node.Index, branch: Ast.full.If) Context.Error!?struct { declaration: u32, then: bool } {
        const branches = [2]?Ast.Node.Index{ branch.ast.then_expr, branch.ast.else_expr.unwrap() };
        for (branches) |side| {
            const node = side orelse continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = f.tree.blockStatements(&buffer, node) orelse &[_]Ast.Node.Index{node};
            for (statements) |candidate| {
                const set = f.setsFlag(candidate) orelse continue;
                const declared = f.flagDeclared(set.declaration) orelse continue;
                if (!try f.flagWritesIn(set.declaration, branches)) continue;
                if (loopOf(f.model, f.tree, f.model.declarations[set.declaration].node) != loopOf(f.model, f.tree, stmt)) continue;
                const then_value = f.flagPast(branch.ast.then_expr, set.declaration) orelse declared;
                const else_value = if (branches[1]) |other| f.flagPast(other, set.declaration) orelse declared else declared;
                if (then_value != else_value) return .{ .declaration = set.declaration, .then = then_value };
            }
        }
        return null;
    }

    /// `flag = true` or `flag = false` of a local: the flag's declaration and the value.
    fn setsFlag(f: Flow, stmt: Ast.Node.Index) ?struct { declaration: u32, value: bool } {
        if (f.tree.nodeTag(stmt) != .assign) return null;
        const data = f.tree.nodeData(stmt).node_and_node;
        if (f.tree.nodeTag(data[0]) != .identifier) return null;
        const value = literalBool(f.tree, data[1]) orelse return null;
        const ref = f.model.reference(data[0]) orelse return null;
        const declaration = ref.declaration orelse return null;
        const record = f.model.declarations[declaration];
        if (record.kind != .variable or f.model.scopes[record.scope].kind != .block) return null;
        return .{ .declaration = declaration, .value = value };
    }

    /// The literal a `var` is declared with, if it is one.
    fn flagDeclared(f: Flow, declaration: u32) ?bool {
        const variable = f.tree.fullVarDecl(f.model.declarations[declaration].node) orelse return null;
        if (f.tree.tokenTag(variable.ast.mut_token) != .keyword_var) return null;
        return literalBool(f.tree, variable.ast.init_node.unwrap() orelse return null);
    }

    /// The value a branch leaves the flag at when it falls through: its last top-level setting.
    fn flagPast(f: Flow, node: Ast.Node.Index, declaration: u32) ?bool {
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = f.tree.blockStatements(&buffer, node) orelse &[_]Ast.Node.Index{node};
        var value: ?bool = null;
        for (statements) |stmt| if (f.setsFlag(stmt)) |set| {
            if (set.declaration == declaration) value = set.value;
        };
        return value;
    }

    /// Whether every write of the flag is a top-level literal setting in one of `branches`, and
    /// nothing takes its address.
    fn flagWritesIn(f: Flow, declaration: u32, branches: [2]?Ast.Node.Index) Context.Error!bool {
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const ref = f.model.reference(node) orelse continue;
            if (ref.declaration != declaration) continue;
            const parent = f.model.node_parents[i] orelse return false;
            switch (f.tree.nodeTag(parent)) {
                .address_of => return false,
                .assign => if (f.tree.nodeData(parent).node_and_node[0] == node) {
                    const place = f.model.node_parents[@backingInt(parent)] orelse return false; // safe: an AST node index reads its own parent table
                    for (branches) |side| {
                        const branch = side orelse continue;
                        if (place == branch or parent == branch) break;
                    } else return false;
                    if (f.setsFlag(parent) == null) return false;
                },
                .assign_mul, .assign_div, .assign_mod, .assign_add, .assign_sub, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_xor, .assign_bit_or, .assign_mul_wrap, .assign_add_wrap, .assign_sub_wrap, .assign_mul_sat, .assign_add_sat, .assign_sub_sat, .assign_shl_sat => if (f.tree.nodeData(parent).node_and_node[0] == node) return false,
                else => {},
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
        var heads: [2]Ast.Node.Index = undefined;
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
        const token = f.model.declarations[ref.declaration orelse return false].token;
        return token == capture or token == capture + 1;
    }

    /// The move (`moves`) `node`, a name of the owner, is the receiver or the optional of.
    fn moveOf(f: Flow, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
        const parent = f.model.node_parents[@backingInt(node)] orelse return null; // safe: an AST node index reads its own parent table
        if (f.tree.nodeTag(parent) == .field_access) {
            const call = f.model.node_parents[@backingInt(parent)] orelse return null; // safe: an AST node index reads its own parent table
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
            const parent = f.model.node_parents[@backingInt(child)] orelse return null; // safe: an AST node index reads its own parent table
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
        var at = f.model.node_parents[@backingInt(jumping)]; // safe: an AST node index reads its own parent table
        while (at) |parent| : ({
            child = parent;
            at = f.model.node_parents[@backingInt(parent)]; // safe: an AST node index reads its own parent table
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
        var at = f.model.node_parents[@backingInt(node)]; // safe: an AST node index reads its own parent table
        while (at) |parent| : (at = f.model.node_parents[@backingInt(parent)]) { // safe: an AST node index reads its own parent table
            if (parent == f.scope) return true;
        }
        return false;
    }

    /// The operand and the handler of a statement that is, assigns or declares `a catch h` or
    /// `a orelse h`.
    fn handled(f: Flow, stmt: Ast.Node.Index) ?[2]Ast.Node.Index {
        const value = if (f.tree.fullVarDecl(stmt)) |v| v.ast.init_node.unwrap() orelse return null else if (f.tree.nodeTag(stmt) == .assign) f.tree.nodeData(stmt).node_and_node[1] else stmt;
        return switch (f.tree.nodeTag(value)) {
            .@"catch", .@"orelse" => f.tree.nodeData(value).node_and_node,
            else => null,
        };
    }

    /// Whether `value` carries the owner itself: it names it by value (not through a member or
    /// its address) at least once.
    fn carried(f: Flow, value: Ast.Node.Index) Context.Error!bool {
        const first = f.tree.firstToken(value);
        const last = f.tree.lastToken(value);
        var found = false;
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const main = f.tree.nodeMainToken(candidate);
            if (main < first or main > last or !f.mine(candidate)) continue;
            const parent = f.model.node_parents[i] orelse return false;
            switch (f.tree.nodeTag(parent)) {
                .address_of => return false,
                .field_access => if (f.tree.nodeData(parent).node_and_token[0] == candidate) continue,
                else => if (fieldOf(f.tree, parent, candidate)) continue,
            }
            found = true;
        }
        return found;
    }

    /// The local a statement of the owner's own block moves the owner into: a declaration
    /// whose initializer is a struct literal that holds the owner as a field's value, nowhere
    /// else, with the owner named nowhere after it. Its obligation is then that local's.
    fn movedInto(f: Flow, stmt: Ast.Node.Index) Context.Error!?Ast.TokenIndex {
        if (f.model.node_parents[@backingInt(stmt)] != f.scope) return null; // safe: an AST node index reads its own parent table
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

    fn mine(f: Flow, node: Ast.Node.Index) bool {
        if (f.tree.nodeTag(node) != .identifier) return false;
        const ref = f.model.reference(node) orelse return false;
        const index = ref.declaration orelse return false;
        return f.model.declarations[index].token == f.token;
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
            if (f.model.declarations[index].token != f.token) continue;
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
            if (f.tree.nodeTag(parent) != .field_access or f.tree.nodeData(parent).node_and_token[0] != candidate) return .other;
            const member = try Model.identifier(f.c.allocator, f.tree.tokenSlice(f.tree.nodeData(parent).node_and_token[1]));
            // A move hands the owner on, as a release ends it (`kept`).
            if (releaseName(f.kind, member) or f.kind == .owned and std.mem.eql(u8, member, "move")) return .other;
            found = .members;
        }
        return found;
    }

    /// `owner = x.init(...)`, `x.adopt(...)` or any acquisition of a guard: live again.
    fn reacquired(f: Flow, stmt: Ast.Node.Index) Context.Error!bool {
        if (f.tree.nodeTag(stmt) != .assign) return false;
        const data = f.tree.nodeData(stmt).node_and_node;
        const index = Contract.local(f.c, data[0]) orelse return false;
        if (f.model.declarations[index].token != f.token) return false;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const value = if (f.tree.nodeTag(data[1]) == .@"try") f.tree.nodeData(data[1]).node else data[1];
        const call = f.tree.fullCall(&call_buffer, value) orelse return false;
        if (f.tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
        const operation = try Model.identifier(f.c.allocator, f.tree.tokenSlice(f.tree.nodeData(call.ast.fn_expr).node_and_token[1]));
        return std.mem.eql(u8, operation, "init") or std.mem.eql(u8, operation, "adopt") or Contract.acquisition(operation) or try givesOwner(f.c, value, call.ast.fn_expr);
    }

    /// `owner.handOff()` kept in a local or assigned: the guard's release passes to the code
    /// the hand-off is given, a transfer declared where it happens, so the walk need not
    /// follow it there. Discarded (`_ = owner.handOff()`), it releases nothing.
    fn handedOff(f: Flow, stmt: Ast.Node.Index) Context.Error!bool {
        const value = if (f.tree.fullVarDecl(stmt)) |v| v.ast.init_node.unwrap() orelse return false else if (f.tree.nodeTag(stmt) == .assign) blk: {
            const data = f.tree.nodeData(stmt).node_and_node;
            if (f.tree.nodeTag(data[0]) == .identifier and std.mem.eql(u8, f.tree.tokenSlice(f.tree.nodeMainToken(data[0])), "_")) return false;
            break :blk data[1];
        } else return false;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = f.tree.fullCall(&buffer, value) orelse return false;
        if (f.tree.nodeTag(call.ast.fn_expr) != .field_access or call.ast.params.len != 0) return false;
        const data = f.tree.nodeData(call.ast.fn_expr).node_and_token;
        const index = Contract.local(f.c, data[0]) orelse return false;
        return f.model.declarations[index].token == f.token and std.mem.eql(u8, try Model.identifier(f.c.allocator, f.tree.tokenSlice(data[1])), "handOff");
    }

    /// A statement that is a call, or keeps or tries its result, with the owner itself among
    /// its arguments and named nowhere else in the statement, to a function outside the
    /// program's own sources (std's containers, a dependency's): one that takes an owner by
    /// value keeps it, as a `put` or an `append` does. A function of the program's own is not
    /// walked for what it does with its parameter, so a call to one stays undecided.
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
        const callee = (try f.c.facts.definition(f.c.file, call.ast.fn_expr)) orelse return false;
        if (f.c.project.inputs[callee.file.raw()].selected) return false;
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
            if (if (f.pointer) f.mine(param) else f.tree.nodeTag(param) == .address_of and f.mine(f.tree.nodeData(param).node)) break i;
        } else return null;
        const first = f.tree.firstToken(value);
        const last = f.tree.lastToken(value);
        var named: usize = 0;
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const main = f.tree.nodeMainToken(candidate);
            if (main >= first and main <= last and f.mine(candidate)) named += 1;
        }
        if (named != 1) return null;
        const decl = (try f.c.facts.definition(f.c.file, call.ast.fn_expr)) orelse return null;
        const function = (try f.c.facts.origin(decl)) orelse return null;
        if (!f.c.project.inputs[function.file.raw()].selected or try f.c.inLibrary(Contract.library, function.file)) return null;
        const model = &f.c.project.models[function.file.raw()];
        const record = model.declarations[function.index];
        if (record.kind != .function) return null;
        const written = &f.c.project.files[function.file.raw()].tree;
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const proto = written.fullFnProto(&proto_buffer, record.node) orelse return null;
        const whole_fn = if (written.nodeTag(record.node) == .fn_decl) record.node else model.node_parents[@backingInt(record.node)] orelse return null; // safe: an AST node index reads its own parent table
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
            const truth = literalBool(f.tree, call.ast.params[at - skip]) orelse continue;
            const name = param.name_token orelse continue;
            for (model.declarations, 0..) |d, i| if (d.kind == .parameter and d.token == name) {
                known = .{ .flag = @intCast(i), .value = truth };
            };
        }
        var heard: Heard = .{ .outer = f.c.sink };
        var probe = f.c.*;
        probe.file = function.file;
        probe.sink = heard.sink();
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
                const declaration = f.model.declarations[ref.declaration orelse return false];
                return switch (declaration.kind) {
                    .parameter => true,
                    .variable => switch (f.model.scopes[declaration.scope].kind) {
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
        return f.model.declarations[index].token == f.token;
    }
};

/// What a reading of another file for a call's sake heard: findings and undecided sites there,
/// kept from the report as that file's own.
const Heard = struct {
    any: bool = false,
    /// The run's own sink, which knows each file's configuration.
    outer: Context.Sink,

    fn sink(heard: *Heard) Context.Sink {
        return .{ .data = heard, .diagnostic = diagnostic, .coverage = coverage, .config = config };
    }
    fn config(data: *anyopaque, file: @import("Project.zig").FileId) @import("Rule.zig").Config {
        const heard: *Heard = @ptrCast(@alignCast(data)); // aegis: internal: `sink` gives this callback a Heard.
        return heard.outer.config(heard.outer.data, file);
    }
    fn diagnostic(data: *anyopaque, _: Rule, _: u32, _: u32, _: []const u8, _: []const Report.Span, _: []const Report.Edit) Context.Error!void {
        const heard: *Heard = @ptrCast(@alignCast(data)); // aegis: internal: `sink` gives this callback a Heard.
        heard.any = true;
    }
    fn coverage(data: *anyopaque, _: Report.Coverage) Context.Error!void {
        const heard: *Heard = @ptrCast(@alignCast(data)); // aegis: internal: `sink` gives this callback a Heard.
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
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    const call_node = model.node_parents[@backingInt(argument)] orelse return false; // safe: an AST node index reads its own parent table
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
    const decl = (try c.facts.definition(file, call.ast.fn_expr)) orelse return false;
    const function = (try c.facts.origin(decl)) orelse return false;
    if (try c.inLibrary(Contract.library, function.file)) return false;
    const record = c.project.models[function.file.raw()].declarations[function.index];
    if (record.kind != .function) return false;
    const written = &c.project.files[function.file.raw()].tree;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = written.fullFnProto(&proto_buffer, record.node) orelse return false;
    // The declaration's node is its prototype, or the whole declaration; its body is the latter's.
    const whole = if (written.nodeTag(record.node) == .fn_decl) record.node else c.project.models[function.file.raw()].node_parents[@backingInt(record.node)] orelse return false; // safe: an AST node index reads its own parent table
    if (written.nodeTag(whole) != .fn_decl) return false;
    var params: [32]Ast.TokenIndex = undefined;
    var count: usize = 0;
    var it = proto.iterate(written);
    while (it.next()) |param| {
        if (count == params.len) return false;
        params[count] = param.name_token orelse return false;
        count += 1;
    }
    // A method called on a value takes the value as its first parameter.
    const skip: usize = if (count == call.ast.params.len + 1) 1 else if (count == call.ast.params.len) 0 else return false;
    const loan: Loan = .{ .c = c, .file = function.file, .tree = written, .model = &c.project.models[function.file.raw()], .token = params[position + skip], .depth = depth + 1 };
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
        return l.model.declarations[index].token == l.token;
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
        while (at) |parent| : (at = model.node_parents[@backingInt(parent)]) { // safe: an AST node index reads its own parent table
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
    if (tree.nodeTag(value) == .error_value) return true;
    return try c.facts.resolve(c.file, value) == .error_set;
}

/// `true` or `false`.
fn literalBool(tree: *const Ast, node: Ast.Node.Index) ?bool {
    if (tree.nodeTag(node) != .identifier) return null;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    if (std.mem.eql(u8, name, "true")) return true;
    if (std.mem.eql(u8, name, "false")) return false;
    return null;
}

/// The innermost `while` or `for` around `node` within its function, whose passes it runs in.
fn loopOf(model: *const Model, tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    var child = node;
    var at = model.node_parents[@backingInt(node)]; // safe: an AST node index reads its own parent table
    while (at) |parent| : ({
        child = parent;
        at = model.node_parents[@backingInt(parent)]; // safe: an AST node index reads its own parent table
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
    return releaseName(k, (try ownerCall(c, node, token)) orelse return false);
}
/// The member `node` calls on the local `token` declares, if it is such a call.
fn ownerCall(c: *Context, node: Ast.Node.Index, token: Ast.TokenIndex) Context.Error!?[]const u8 {
    const tree = try c.project.syntax(try c.source());
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const data = tree.nodeData(call.ast.fn_expr).node_and_token;
    const index = Contract.local(c, data[0]) orelse return null;
    if (c.project.models[c.file.raw()].declarations[index].token != token) return null;
    return try Model.identifier(c.allocator, tree.tokenSlice(data[1]));
}
fn raw(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access or call.ast.params.len != 0) return false;
    const data = tree.nodeData(call.ast.fn_expr).node_and_token;
    if (!std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(data[1])), "raw")) return false;
    return try requiredOwner(c, data[0], scalar, data[1]) == .scalar;
}
fn checkScalar(c: *Context) Context.Error!void {
    if (!try begin(c, scalar)) return;
    const tree = try c.project.syntax(try c.source());
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tag) {
            .add, .sub, .mul, .div, .mod, .shl, .add_wrap, .sub_wrap, .mul_wrap, .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal => {
                const operands = tree.nodeData(node).node_and_node;
                if (try raw(c, operands[0]) or try raw(c, operands[1])) try c.at(scalar, tree.nodeMainToken(node), "raw aegis scalar operation bypasses domain/unit or checked arithmetic; explicit boundary semantics required");
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                if (!std.mem.eql(u8, name, "@intCast") and !std.mem.eql(u8, name, "@truncate") and !std.mem.eql(u8, name, "@enumFromInt")) continue;
                var buffer: [2]Ast.Node.Index = undefined;
                for (Facts.builtinArgs(tree, node, &buffer)) |arg| if (try raw(c, arg)) try c.at(scalar, tree.nodeMainToken(node), "raw aegis scalar cast can discard domain/range/all-build failure checks; use checked conversion or justify boundary");
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
const Path = struct { root: u32, chain: []const []const u8 };

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
const Frame = struct { function: u32, call: Ast.Node.Index };

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
fn parameterPosition(c: *Context, function: u32, decl: u32) ?usize {
    const tree = &c.project.files[c.file.raw()].tree; // safe: the checked source handle indexes the frozen file table.
    const model = &c.project.models[c.file.raw()]; // safe: the checked source handle indexes the frozen model table.
    if (model.declarations[decl].kind != .parameter) return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[function].node) orelse return null;
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) if (param.name_token == model.declarations[decl].token) return position;
    return null;
}

/// Whether `decl` is declared inside `function`'s body or among its parameters.
fn within(c: *Context, decl: u32, function: u32) bool {
    const tree = &c.project.files[c.file.raw()].tree; // safe: the checked source handle indexes the frozen file table.
    const model = &c.project.models[c.file.raw()]; // safe: the checked source handle indexes the frozen model table.
    const node = model.declarations[function].node;
    const whole_fn = model.node_parents[@backingInt(node)] orelse node; // safe: an AST node index reads its own parent table
    const token = model.declarations[decl].token;
    return tree.firstToken(whole_fn) <= token and token <= tree.lastToken(whole_fn);
}

/// The argument `call` passes at `function`'s parameter `position`: a method called on a value
/// takes the value first.
fn argumentAt(c: *Context, function: u32, call_node: Ast.Node.Index, position: usize) ?Ast.Node.Index {
    const tree = &c.project.files[c.file.raw()].tree; // safe: the checked source handle indexes the frozen file table.
    const model = &c.project.models[c.file.raw()]; // safe: the checked source handle indexes the frozen model table.
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, call_node) orelse return null;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, model.declarations[function].node) orelse return null;
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
    const model = &c.project.models[c.file.raw()];
    switch (tree.nodeTag(node)) {
        .grouped_expression => return wholeBytes(c, tree.nodeData(node).node_and_token[0], want, frames, until, depth + 1),
        .@"try" => return wholeBytes(c, tree.nodeData(node).node, want, frames, until, depth + 1),
        // The other side does not complete: the value is the operand's.
        .@"catch", .@"orelse" => {
            const sides = tree.nodeData(node).node_and_node;
            if (!completesNot(tree, sides[1])) return false;
            return wholeBytes(c, sides[0], want, frames, until, depth + 1);
        },
        .identifier => {
            const index = Contract.local(c, node) orelse return false;
            const decl = model.declarations[index];
            switch (decl.kind) {
                .variable => {
                    if (model.scopes[decl.scope].kind != .block) return false;
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
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        const data = tree.nodeData(call.ast.fn_expr).node_and_token;
        const name = try Model.identifier(c.allocator, tree.tokenSlice(data[1]));
        const made = if (std.mem.eql(u8, name, "alloc") or std.mem.eql(u8, name, "dupe"))
            call.ast.params.len == 2 and isByte(c, call.ast.params[0])
        else
            std.mem.eql(u8, name, "print") and call.ast.params.len == 2;
        if (made) {
            const expected = want orelse return true;
            const giver = (try pathOf(c, data[0])) orelse return false;
            const read = (try outward(c, giver, frames)) orelse return false;
            return samePaths(read, expected);
        }
    }
    // A function of this file: what it returns on every path that gives a value.
    const callee = (try c.facts.definition(c.file, call.ast.fn_expr)) orelse return false;
    const function = (try c.facts.origin(callee)) orelse return false;
    if (!function.file.eql(c.file) or model.declarations[function.index].kind != .function) return false;
    const body_fn = model.node_parents[@backingInt(model.declarations[function.index].node)] orelse return false; // safe: an AST node index reads its own parent table
    if (tree.nodeTag(body_fn) != .fn_decl) return false;
    const inner = try std.mem.concat(c.allocator, Frame, &.{ frames, &.{.{ .function = function.index, .call = node }} });
    var gives = false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const ret: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (enclosingFunction(tree, model, ret) != body_fn) continue;
        const value = tree.nodeData(ret).opt_node.unwrap() orelse continue;
        if (tree.nodeTag(value) == .error_value) continue;
        if (tree.nodeTag(value) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "null")) continue;
        if (!try wholeBytes(c, value, want, inner, tree.lastToken(ret), depth + 1)) return false;
        gives = true;
    }
    return gives;
}

/// Whether `node` never completes with a value: `return`, `unreachable`, a `break` or
/// `continue`.
fn completesNot(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .@"return", .unreachable_literal, .@"break", .@"continue" => true,
        else => false,
    };
}

fn isByte(c: *Context, node: Ast.Node.Index) bool {
    const tree = &c.project.files[c.file.raw()].tree; // safe: the checked source handle indexes the frozen file table.
    if (tree.nodeTag(node) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "u8")) return false;
    const ref = c.project.models[c.file.raw()].reference(node) orelse return true;
    return ref.declaration == null;
}

/// The `fn_decl` whose body holds `node`, nearest first.
fn enclosingFunction(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Ast.Node.Index {
    var up = model.node_parents[@backingInt(node)]; // safe: an AST node index reads its own parent table
    while (up) |parent| : (up = model.node_parents[@backingInt(parent)]) { // safe: an AST node index reads its own parent table
        if (tree.nodeTag(parent) == .fn_decl) return parent;
    }
    return null;
}

/// Whether the local `index` is named, apart from at `read`, only before `until` and never in
/// deferred code: what it holds is the reader's alone from there.
fn heldAlone(c: *Context, index: u32, read: Ast.Node.Index, until: Ast.TokenIndex) bool {
    const tree = &c.project.files[c.file.raw()].tree; // safe: the checked source handle indexes the frozen file table.
    const model = &c.project.models[c.file.raw()]; // safe: the checked source handle indexes the frozen model table.
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (candidate == read) continue;
        const ref = model.reference(candidate) orelse continue;
        if (ref.declaration != index) continue;
        if (tree.nodeMainToken(candidate) > until) return false;
        var up = model.node_parents[i];
        while (up) |parent| : (up = model.node_parents[@backingInt(parent)]) { // safe: an AST node index reads its own parent table
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
fn passedWhole(c: *Context, index: u32, want: ?Path, depth: usize) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    const model = &c.project.models[c.file.raw()];
    const function: u32 = for (model.declarations, 0..) |d, i| {
        if (d.kind == .function and parameterPosition(c, @intCast(i), index) != null) break @intCast(i);
    } else return false;
    const record = model.declarations[function];
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
