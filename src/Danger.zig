//! The aegis pack's danger rules whose predicates need no flow fact (designs/aegis.md §7): each
//! finds the sites where a danger exists and aegis's type is the answer, from what the code
//! resolves to, never from a name it merely spells. A site that stands raw carries the pack's
//! escape, `// aegis: <reason>(<rule>, ...): <why>`; one the rule cannot decide is undecided.
//!
//! Every rule reads production code only: test inputs and test blocks are not shipped. An
//! operation the program runs only as it compiles (in a `comptime` block, a function returning
//! `type`, a container-level declaration's value or a field's default) has none of these
//! dangers; a type a field or variable is declared with is the program's state at run time
//! wherever it is written.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const Escapes = @import("Escapes.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const ParentPointer = @import("ParentPointer.zig");
const Present = @import("Present.zig");
const Project = @import("Project.zig");
const Contract = @import("AegisContract.zig");
const Report = @import("Report.zig");
const Taint = @import("Taint.zig");
const Rule = @import("Rule.zig").Rule;

/// The facts the pack's flow rules ask of the program's values (`Taint.Spec`): input a peer
/// gives, which aegis's parse answers, and the writers that reach a peer.
pub const peer_input: Taint.Spec = .{ .source = .{ .input = .{ .peer = true, .operator = false } }, .control = true, .answers = .{ .aegis = true } };
/// A012's: peer input, and the sizes the program hands std (`Taint.sinkSites`), judged where
/// they are a number.
pub const bounded_input: Taint.Spec = .{ .source = peer_input.source, .control = peer_input.control, .answers = peer_input.answers, .sinks = .{ .size = true }, .reaches = .number };
pub const peer_writer: Taint.Spec = .{ .source = .peer_writer, .control = true };
/// A018's: an error's text, which aegis's public text and an error's integer answer, judged
/// where a peer writer writes it (`Taint.sinkSites`). What an error decides is no text of it.
pub const error_text: Taint.Spec = .{ .source = .error_text, .control = false, .answers = .{ .aegis = true, .int_from_error = true }, .sinks = .{ .peer_write = true } };
const Ast = std.zig.Ast;

/// A007: shared state outside aegis's guards. `Io.Event` is none: a signal set once, which
/// guards no data of its own (what it announces is judged where it is held).
pub fn sharedState(c: *Context, rule: Rule) Context.Error!void {
    const sync = [_][]const u8{ "Io.Mutex", "Io.RwLock", "Io.Condition", "Io.Semaphore", "atomic.Value", "atomic.Mutex" };
    const message = "{s}: raw synchronization; aegis Guarded, BlockingGuarded, RwGuarded, SpinRwGuarded, Condition, Atomic, Once or Lazy holds the data it guards";
    const spelled = try governedHeld(c, rule, &sync, message);
    const held = try heldUnderOtherNames(c, rule, &sync, spelled, message);
    // A futex is a lock or a signal made by hand on a word the program writes as it likes.
    const futex = [_][]const u8{ "Io.futexWait", "Io.futexWaitTimeout", "Io.futexWaitUncancelable", "Io.futexWake", "Io.VTable.futexWait", "Io.VTable.futexWaitUncancelable", "Io.VTable.futexWake" };
    try governed(c, rule, &futex, true, "{s}: a wait or wake on a word the program synchronizes by hand; aegis Atomic, Condition or Once holds the state it signals, Io.Event a signal alone");
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const name = Facts.builtinName(tree, node) orelse continue;
        for ([_][]const u8{ "@atomicLoad", "@atomicStore", "@atomicRmw", "@cmpxchgWeak", "@cmpxchgStrong" }) |atomic| if (std.mem.eql(u8, name, atomic)) {
            if (!c.inTest(tree.nodeMainToken(node)) and atRuntime(c, node)) try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("{s}: a raw atomic; aegis Atomic holds the cell", .{name}));
        };
    }
    const model = &c.project.at(c.file).model;
    for (model.declarations) |decl| {
        if (decl.kind != .variable) continue;
        const scope = model.scopes[@backingInt(decl.scope)].kind;
        if (scope != .file and scope != .container) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_var or variable.threadlocal_token != null) continue;
        // An `extern var` is the unsafe set's (A019): its storage is another program's.
        if (variable.extern_export_token) |token| if (tree.tokenTag(token) == .keyword_extern) continue;
        if (c.inTest(decl.token)) continue;
        // A variable of a synchronization type is that type's site, counted once; one of an
        // aegis type (`Atomic`, `Guarded`, `Once`, ...) is held by its answer.
        if (variable.ast.type_node.unwrap()) |kind| {
            if (within(tree, held, kind)) continue;
            if (try guards(c, try c.facts.resolve(c.file, kind))) continue;
        }
        try c.at(rule, decl.token, try c.allocator.print("container-level var '{s}': mutable state any thread may reach; aegis Guarded, Atomic, Once or Lazy holds it, or Confined checks its one owner", .{decl.name}));
    }
}

/// Whether a container variable's type holds its state under one of aegis's guards (`Guarded`
/// and its kin, `Condition`, `Once`, `Lazy`, `Confined`, `Atomic`), or is a choice the build makes
/// (`if (builtin.is_test) aegis.Atomic(T) else void`) each of whose types is one or `void`, which
/// holds no state. Another aegis type (an id, a `Shared` handle, an externally serialized
/// `Counter`) guards nothing.
fn guards(c: *Context, value: Facts.Value) Context.Error!bool {
    switch (value) {
        .alternatives => |each| {
            for (each) |one| if (!try guards(c, one)) return false;
            return true;
        },
        .primitive => |name| return std.mem.eql(u8, name, "void"),
        else => return switch ((try c.role(Contract.library, value)) orelse return false) {
            .guarded, .condition, .once, .confined, .atomic => true,
            else => false,
        },
    }
}

/// A008: secret material outside aegis's Secret and Choice. Held by value: a variable, a
/// parameter, a capture, a field or a function's result whose value, by meaning, is one of
/// std's secret types (`secretTypes`) or holds one by value (an array, an optional, an error
/// union of it); behind a pointer it is borrowed, in aegis's `Secret` sealed. Handled by hand:
/// its material's bytes read by value (`for (k.bytes) |b|`, `k.bytes[0]`) or written by a
/// memory builtin (`@memset(&kp.secret_key.bytes, 0)`, a store the optimizer may drop), and
/// std's wipes and constant-time compares called directly. A binding whose value does not
/// resolve is undecided.
pub fn secrets(c: *Context, rule: Rule) Context.Error!void {
    const calls = [_][]const u8{ "crypto.secureZero", "crypto.timing_safe.eql", "crypto.timing_safe.compare" };
    try governed(c, rule, &calls, true, "{s}: secret material handled by hand; aegis Secret and SecretBytes wipe it, Choice compares in constant time");
    const types = try secretTypes(c);
    if (types.len == 0) return;
    try secretBindings(c, rule, types);
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations, 0..) |decl, d| {
        if (c.inTest(decl.token)) continue;
        // A block's local or a capture that exists only as the program compiles (in a type
        // function, a `comptime` block) holds no material, as A007 reads it.
        if ((decl.kind == .capture or (decl.kind == .variable and model.scopes[@backingInt(decl.scope)].kind != .file and model.scopes[@backingInt(decl.scope)].kind != .container)) and !atRuntime(c, decl.node)) continue;
        // A module or file `@import` gives: a namespace, a type, which holds no material.
        if (decl.kind == .variable) if (tree.fullVarDecl(decl.node)) |variable| if (variable.ast.init_node.unwrap()) |init| if (imported(tree, init)) continue;
        const value: Facts.Value = switch (decl.kind) {
            .variable, .parameter, .capture, .field => try c.facts.declaration(.{ .file = c.file, .index = @fromBackingInt(@intCast(d)) }),
            // What calling it gives, as Zig reads its result type (`!T`, a made type).
            .function => try c.facts.callResult(.{ .function = .{ .file = c.file, .index = @fromBackingInt(@intCast(d)) } }, {}),
        };
        switch (try heldSecret(c, types, value)) {
            .no => {},
            .unknown => |why| if (!bindingsJudge(c, why, decl.node) and (why != .comptime_dependent or runtimeState(c, decl))) try c.undecided(rule, tree.tokenStart(decl.token), .unresolved, "a value whose type does not resolve may be std's secret material held by value"),
            .yes => |held| try c.at(rule, decl.token, try c.allocator.print("std.crypto {s} held by value outside aegis Secret: its bytes are copied and never wiped", .{held})),
        }
    }
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        switch (tag) {
            .field_access => if (!c.inTest(token)) try materialRead(c, rule, types, node),
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const name = tree.tokenSlice(token);
                if (!std.mem.eql(u8, name, "@memset") and !std.mem.eql(u8, name, "@memcpy") and !std.mem.eql(u8, name, "@memmove")) continue;
                if (c.inTest(token)) continue;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, node, &buffer);
                if (args.len != 2) continue;
                switch (try placeInSecret(c, types, (try Facts.accesses.sideOf(c.facts, c.file, args[0])).node())) {
                    .no => {},
                    .unknown => |why| if (why != .generic) try c.undecided(rule, tree.tokenStart(token), .unresolved, "memory written by hand whose holder does not resolve may be std's secret material"),
                    .yes => |held| try c.at(rule, token, try c.allocator.print("{s}: std.crypto {s} written by hand, a store the optimizer may drop; aegis Secret wipes it", .{ name, held })),
                }
            },
            else => {},
        }
    }
}

const Secret = union(enum) { yes: []const u8, no, unknown: Facts.Unknown };

/// Whether a value is secret material by value: an instance of one of `types`, or an array, an
/// optional or an error union of one; a choice of them is if one is. A pointer borrows it; a
/// type, a number, a function, an error hold none. Any other value is unknown (`Facts.resolve`'s contract).
/// An instance of a container a type function made holds what a field holds that the function's
/// parameters type and no call it judges binds (`unjudged`): that field is read with this
/// instance's bindings, as nowhere else. aegis's Secret, SecretBytes and Choice hold it sealed.
fn heldSecret(c: *Context, types: []const SecretType, value: Facts.Value) Context.Error!Secret {
    switch (value) {
        .instance => |found| {
            for (types) |t| if (found.file == t.container.file and found.scope == t.container.scope) return .{ .yes = t.name };
            // aegis's Secret, SecretBytes and Choice seal what they hold.
            if (try c.role(Contract.library, value)) |role| switch (role) {
                .secret, .bytes, .choice => return .no,
                else => {},
            };
            var out: Secret = .no;
            for (try unjudgedFields(c, found)) |field| switch (try heldSecret(c, types, field)) {
                .yes => |held| return .{ .yes = held },
                .unknown => |why| out = .{ .unknown = why },
                .no => {},
            };
            return out;
        },
        .array, .optional, .error_union => |inner| return heldSecret(c, types, inner.*),
        // A tuple or struct literal with no type of its own holds each part by value; a part
        // known only as the program compiles (an enum literal, `.{ "pointer", .pointer }`, or
        // one of a choice of such tuples) leaves it so, as such a declaration is.
        .alternatives, .literal => {
            const each = if (value == .literal) try c.facts.literalParts(value.literal) else value.alternatives;
            var out: Secret = .no;
            for (each, 0..) |one, i| switch (if (value == .literal and enumLiteralPart(c, value.literal, i)) .no else try heldSecret(c, types, one)) {
                .yes => |held| return .{ .yes = held },
                .unknown => |why| if (why != .comptime_dependent) {
                    out = .{ .unknown = .unresolved };
                } else if (out == .no) {
                    out = .{ .unknown = why };
                },
                .no => {},
            };
            return out;
        },
        // A type built from its fields' types (`@Struct`): a value of it holds each.
        .reified => |built| return if (built.value) heldSecret(c, types, try c.facts.reifiedParts(built)) else .no,
        .pointer, .container, .primitive, .scalar, .function, .fn_type, .error_set => return .no,
        .unknown => |why| return .{ .unknown = why },
        else => return .{ .unknown = .unsupported },
    }
}

/// Whether a value is unknown only as a generic's binding gives it, no call a run judges
/// binding it (`Facts.boundByCallers`): through what holds it by value.
fn unjudged(value: Facts.Value) bool {
    var current = value;
    while (true) current = switch (current) {
        .array, .optional, .error_union => |inner| inner.*,
        .unknown => |why| return why == .generic,
        else => return false,
    };
}

/// Whether a value left unknown at `node` is judged where a call binds what it depends on: a
/// generic's parameter (`.generic`), or what only the program's compiling settles inside a
/// generic or a type function (`std.meta.Child(T)`), whose bindings are judged. Known only as
/// the program compiles elsewhere (`std.meta.Child(*const Lock)` that does not evaluate), it
/// is undecided.
fn bindingsJudge(c: *Context, why: Facts.Unknown, node: Ast.Node.Index) bool {
    return why == .generic or (why == .comptime_dependent and inGenericCode(c, node));
}

/// Whether a declaration holds state as the program runs: a field, a parameter, a function's
/// result, a `var`, a local or a capture where it runs. A container-level constant is settled as
/// the program compiles.
fn runtimeState(c: *Context, decl: Model.Declaration) bool {
    return switch (decl.kind) {
        .field, .parameter, .function => true,
        .capture => atRuntime(c, decl.node),
        .variable => atRuntime(c, decl.node) or c.project.at(c.file).file.tree.tokenTag((c.project.at(c.file).file.tree.fullVarDecl(decl.node) orelse return true).ast.mut_token) == .keyword_var,
    };
}

/// Whether part `index` of an anonymous literal is an enum literal (`.{ "pointer", .pointer }`):
/// a value only the compiling program holds, which no lock or key is.
fn enumLiteralPart(c: *Context, literal: Facts.Key, index: usize) bool {
    const tree = &c.project.at(literal.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const nodes = if (tree.fullStructInit(&buffer, literal.node)) |full| full.ast.fields else if (tree.fullArrayInit(&buffer, literal.node)) |full| full.ast.elements else return false;
    return index < nodes.len and tree.nodeTag(nodes[index]) == .enum_literal;
}

/// Whether `node` lies in a function with a `comptime`, type or `anytype` parameter, or one
/// returning `type`, or in a container one of those declares.
fn inGenericCode(c: *Context, node: Ast.Node.Index) bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) != .fn_decl) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(parent).node_and_node[0]) orelse continue;
        if (proto.ast.return_type.unwrap()) |result| if (tree.nodeTag(result) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(result)), "type")) return true;
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            if (param.anytype_ellipsis3 != null) return true;
            if (param.comptime_noalias) |token| if (tree.tokenTag(token) == .keyword_comptime) return true;
            if (param.type_expr) |type_expr| if (tree.nodeTag(type_expr) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(type_expr)), "type")) return true;
        }
    }
    return false;
}

/// What an instance holds by value that no declaration of this run judges where it is
/// written, read with the instance's bindings: a tuple's field (`struct { Key, u8 }`, which
/// declares none); a field a type function's parameters type (`unjudged`); and every field of
/// the program's record in a file the run does not select (a dependency's). std's and the
/// known libraries' records are judged by their types alone.
fn unjudgedFields(c: *Context, found: Facts.Container) Context.Error![]const Facts.Value {
    const unselected = !c.project.at(found.file).input.selected and try c.facts.program(found.file);
    if (found.made_by == null and !unselected and !try hasTupleField(c, found)) return &.{};
    var out: std.ArrayList(Facts.Value) = .empty;
    for (try c.facts.heldFields(found)) |field| {
        // A made field's type its template reads only with bindings (`value: T`,
        // `std.meta.Child(T)`) is judged here, with this instance's.
        if (field.decl) |decl| if (!unselected and !madeField(found, try c.facts.declaration(decl))) continue;
        try out.append(c.allocator, field.value);
    }
    return out.items;
}

/// Whether a field of a made container is typed only with its call's bindings: its template
/// reads it as a generic's, or as known only as the program compiles.
fn madeField(found: Facts.Container, declared: Facts.Value) bool {
    if (found.made_by == null) return false;
    var current = declared;
    while (true) current = switch (current) {
        .array, .optional, .error_union => |inner| inner.*,
        .unknown => |why| return why == .generic or why == .comptime_dependent,
        else => return false,
    };
}

/// Whether a container declares a tuple's field, which no declaration judges.
fn hasTupleField(c: *Context, found: Facts.Container) Context.Error!bool {
    const tree = &c.project.at(found.file).file.tree;
    const node = c.project.at(found.file).model.scopes[@backingInt(found.scope)].node;
    if (node == .root) return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, node) orelse return false;
    const model = &c.project.at(found.file).model;
    for (container.ast.members) |item| if (model.containerField(tree, item)) |field| if (field.ast.tuple_like) return true;
    return false;
}

/// A008 at a binding: a call that binds a generic's parameter no call it judges binds
/// (`unjudged`), where the binding makes the parameter, or a value the generic makes of it,
/// secret material by value. A type bound where the generic copies or makes a value of it; a
/// value bound where it is passed by value, a temporary or a call's result (a local's own
/// declaration holds it).
fn secretBindings(c: *Context, rule: Rule, types: []const SecretType) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (try Facts.calls.in(c.facts, c.file)) |call| {
        if (c.inTest(tree.nodeMainToken(call.node))) continue;
        const functions: []const Facts.Decl = switch (call.callee) {
            .function => |function| &.{function},
            .choice => |each| each,
            // What it binds is read where it does resolve.
            .any => continue,
        };
        for (functions) |function| {
            // aegis's own functions are its safe types' internals: Secret, SecretBytes and Choice
            // hold what they are bound to sealed, and an instance of another of its types that
            // holds secret material is judged where it is declared (`heldSecret`).
            if (try c.inLibrary(Contract.library, function.file)) continue;
            const source = c.project.at(function.file);
            var buffer: [1]Ast.Node.Index = undefined;
            const proto = source.file.tree.fullFnProto(&buffer, source.model.declarations[@backingInt(function.index)].node) orelse continue;
            var it = proto.iterate(&source.file.tree);
            var position: usize = 0;
            while (it.next()) |param| : (position += 1) {
                if (call.args == .known and position >= call.args.known.len) break;
                const name = param.name_token orelse continue;
                const parameter = for (source.model.declarations, 0..) |d, i| {
                    if (d.kind == .parameter and d.token == name) break Facts.Decl{ .file = function.file, .index = @fromBackingInt(@intCast(i)) };
                } else continue;
                // A generic's own site judges what its callers bind, unless its file is no
                // selected one's, as a dependency's: there the binding is judged here.
                if (!unjudged(try c.facts.declaration(parameter)) and (source.input.selected or !genericParameter(&source.file.tree, proto, param))) continue;
                const argument = switch (call.args) {
                    .known => |known| known[position],
                    .unknown => {
                        try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(call.node)), .unresolved, "a call whose arguments are not known binds a generic's parameter: it may make it std's secret material held by value");
                        break;
                    },
                };
                const typed = if (param.type_expr) |t| source.file.tree.nodeTag(t) == .identifier and std.mem.eql(u8, source.file.tree.tokenSlice(source.file.tree.nodeMainToken(t)), "type") else false;
                if (typed) {
                    const made = for (try c.facts.parameterCopies(function)) |copy| {
                        if (copy.position == position and copy.kind != .cast) break true;
                    } else false;
                    const kept: Governed.Is = if (made) .yes else holdsParameter(c, function, source.file.tree.tokenSlice(name));
                    if (kept == .no) continue;
                    const bound: Facts.Value = switch (try c.facts.resolve(c.file, argument)) {
                        .container => |container| .{ .instance = container },
                        .unknown => |why| .{ .unknown = why },
                        else => continue,
                    };
                    switch (kept) {
                        .yes => try boundSecret(c, rule, types, argument, bound),
                        .no => {},
                        // The enclosing generic's own parameter is judged at its bindings.
                        .unknown => if (switch (try heldSecret(c, types, bound)) {
                            .no => false,
                            .unknown => |why| !bindingsJudge(c, why, argument),
                            .yes => true,
                        }) try c.undecided(rule, tree.tokenStart(tree.firstToken(argument)), .unsupported, "a generic names its type parameter where A008 does not read whether it holds a value of it: binding it to std's secret material may hold that by value"),
                    }
                    continue;
                }
                // A value passed whole: each part it copies. A local's or a field's is held by
                // value where it is declared, and judged there.
                const parts = try c.facts.copiedParts(c.file, argument);
                if (parts.deep) |deep| try c.undecided(rule, tree.tokenStart(tree.firstToken(deep)), .unsupported, "a value bound to a generic's parameter is nested past the depth A008 follows: secret material it copies is not ruled out");
                for (parts.places) |place| switch (tree.nodeTag(place)) {
                    .identifier, .field_access => {},
                    else => try boundSecret(c, rule, types, place, try c.facts.resolve(c.file, place)),
                };
                for (parts.rest) |part| try boundSecret(c, rule, types, part, try c.facts.resolve(c.file, part));
                // A call's result handed on: a temporary the generic holds.
                for (parts.results) |result| try boundSecret(c, rule, types, result, try c.facts.resolve(c.file, result));
            }
        }
    }
}

/// Whether `function` holds a value of its type parameter `name` by value, at each place its
/// body names it: a variable, a field (of a container it makes) or a parameter declared of it,
/// an optional, an array or an error union of it, a result of it, `@as(name, v)`, do; one
/// behind a pointer, an array's length, `@sizeOf(name)` and its kin, and a comparison of it
/// hold none. Any other place is unknown.
fn holdsParameter(c: *Context, function: Facts.Decl, name: []const u8) Governed.Is {
    const source = c.project.at(function.file);
    const t = &source.file.tree;
    const model = &source.model;
    const proto = model.declarations[@backingInt(function.index)].node;
    const whole = model.parentOf(proto) orelse proto;
    const first = t.firstToken(whole);
    const last = t.lastToken(whole);
    var out: Governed.Is = .no;
    for (t.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = t.nodeMainToken(node);
        if (token < first or token > last or !std.mem.eql(u8, t.tokenSlice(token), name)) continue;
        switch (holdsAt(t, model, node)) {
            .yes => return .yes,
            .no => {},
            .unknown => |why| out = .{ .unknown = why },
        }
    }
    return out;
}

/// `holdsParameter` at one place `node` names the type parameter.
fn holdsAt(t: *const Ast, model: *const Model, node: Ast.Node.Index) Governed.Is {
    var at = node;
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const parent = model.parentOf(at) orelse return .{ .unknown = .unsupported };
        var buffer: [1]Ast.Node.Index = undefined;
        if (t.fullPtrType(parent) != null) return .no;
        if (t.fullArrayType(parent)) |array| {
            if (array.ast.elem_type != at) return .no;
            at = parent;
            continue;
        }
        if (t.fullVarDecl(parent)) |v| return if (v.ast.type_node.unwrap() == at) .yes else .{ .unknown = .unsupported };
        if (model.containerField(t, parent)) |field| return if (field.ast.type_expr.unwrap() == at) .yes else .{ .unknown = .unsupported };
        if (t.fullFnProto(&buffer, parent)) |_| return .yes;
        switch (t.nodeTag(parent)) {
            .optional_type => at = parent,
            .error_union => {
                if (t.nodeData(parent).node_and_node[1] != at) return .no;
                at = parent;
            },
            .equal_equal, .bang_equal => return .no,
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const builtin = t.tokenSlice(t.nodeMainToken(parent));
                for ([_][]const u8{ "@sizeOf", "@alignOf", "@bitSizeOf", "@typeName", "@typeInfo", "@hasDecl", "@hasField" }) |inert| if (std.mem.eql(u8, builtin, inert)) return .no;
                return if (std.mem.eql(u8, builtin, "@as")) .yes else .{ .unknown = .unsupported };
            },
            else => return .{ .unknown = .unsupported },
        }
    }
    return .{ .unknown = .unsupported };
}

/// Whether a parameter is a generic's: its type is written with `type`, or the name of one of
/// the function's parameters (`value: T`, `items: ?[4]T`), or it is `anytype`.
fn genericParameter(tree: *const Ast, proto: Ast.full.FnProto, param: Ast.full.FnProto.Param) bool {
    const written = param.type_expr orelse return true;
    for (tree.firstToken(written)..tree.lastToken(written) + 1) |t| {
        const token: Ast.TokenIndex = @intCast(t);
        if (tree.tokenTag(token) != .identifier) continue;
        const spelled = tree.tokenSlice(token);
        if (std.mem.eql(u8, spelled, "type")) return true;
        var it = proto.iterate(tree);
        while (it.next()) |other| if (other.name_token) |name| if (std.mem.eql(u8, tree.tokenSlice(name), spelled)) return true;
    }
    return false;
}

/// A008 for `value`, what a binding at `node` makes a generic's parameter hold by value.
fn boundSecret(c: *Context, rule: Rule, types: []const SecretType, node: Ast.Node.Index, value: Facts.Value) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    switch (try heldSecret(c, types, value)) {
        .yes => |held| try c.at(rule, tree.firstToken(node), try c.allocator.print("std.crypto {s} bound to a generic's parameter, held by value there outside aegis Secret: its bytes are copied and never wiped", .{held})),
        .no => {},
        .unknown => |why| if (!bindingsJudge(c, why, node)) try c.undecided(rule, tree.tokenStart(tree.firstToken(node)), .unresolved, "a binding of a generic's parameter that does not resolve may make it std's secret material held by value"),
    }
}

/// Whether a place (`kp.secret_key.bytes`, `k.bytes[0..]`) lies in secret material: one of its
/// holders up the place, through pointers, is one of `types`.
fn placeInSecret(c: *Context, types: []const SecretType, place: Ast.Node.Index) Context.Error!Secret {
    const tree = &c.project.at(c.file).file.tree;
    var at = place;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        var value = try c.facts.resolve(c.file, at);
        while (value == .pointer) value = value.pointer.*;
        switch (try heldSecret(c, types, value)) {
            .yes => |held| return .{ .yes = held },
            .unknown => |why| return .{ .unknown = why },
            .no => {},
        }
        at = switch (tree.nodeTag(at)) {
            .field_access => tree.nodeData(at).node_and_token[0],
            .array_access => tree.nodeData(at).node_and_node[0],
            .deref => tree.nodeData(at).node,
            .grouped_expression => tree.nodeData(at).node_and_token[0],
            .slice_open => tree.nodeData(at).node_and_node[0],
            .slice, .slice_sentinel => tree.nodeData(at).node_and_extra[0],
            else => return .no,
        };
    }
    return .no;
}

/// A field of secret material read by value (`for (k.bytes) |b|`, `k.bytes[0]`, `k.secret_key`
/// copied), not behind `&` and not a method's receiver: its bytes leave what wipes them. A
/// type's declaration read (`SecretKey.encoded_length`) holds none; std's public halves
/// (`public_key`) are no material.
fn materialRead(c: *Context, rule: Rule, types: []const SecretType, node: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const object, const member = tree.nodeData(node).node_and_token;
    if (std.mem.eql(u8, tree.tokenSlice(member), "public_key")) return;
    var holder = try c.facts.resolve(c.file, object);
    while (holder == .pointer) holder = holder.pointer.*;
    const held = switch (try heldSecret(c, types, holder)) {
        .yes => |held| held,
        .no, .unknown => return,
    };
    const field = switch (try c.facts.definition(c.file, node)) {
        .decl => |field| field,
        // A member std's secret material does not declare is no field of it.
        .none => return,
        .unknown => return c.undecided(rule, tree.tokenStart(member), .unresolved, "a member of std's secret material that does not resolve may be its bytes read by value"),
    };
    if (c.project.at(field.file).model.declarations[@backingInt(field.index)].kind != .field) return;
    // Up the place it is part of: what is done with the whole decides.
    var top = node;
    while (model.parentOf(top)) |parent| {
        const part = switch (tree.nodeTag(parent)) {
            .field_access => tree.nodeData(parent).node_and_token[0] == top,
            .array_access => tree.nodeData(parent).node_and_node[0] == top,
            .grouped_expression => true,
            .slice_open => tree.nodeData(parent).node_and_node[0] == top,
            .slice, .slice_sentinel => tree.nodeData(parent).node_and_extra[0] == top,
            else => false,
        };
        if (!part) break;
        // A method called on it (`kp.secret_key.seed()`) is std's own handling.
        if (tree.nodeTag(parent) == .field_access) switch (try c.facts.definition(c.file, parent)) {
            .decl => |d| if (c.project.at(d.file).model.declarations[@backingInt(d.index)].kind == .function) return,
            .none => {},
            .unknown => return c.undecided(rule, tree.tokenStart(member), .unresolved, "a member of std's secret material whose use does not resolve may be its bytes read by value"),
        };
        top = parent;
    }
    if (model.parentOf(top)) |parent| switch (tree.nodeTag(parent)) {
        .address_of => return,
        else => {},
    };
    // A slice of it is a borrow too, unless its elements are read.
    if (try c.facts.resolve(c.file, top) == .pointer) return;
    try c.at(rule, member, try c.allocator.print("std.crypto {s}'s material read by value outside aegis Secret: its bytes are copied and never wiped; aegis Choice compares them", .{held}));
}

const SecretType = struct { container: Facts.Container, name: []const u8 };

/// std's secret types, by declaration: the `SecretKey`, `KeyPair`, `BlindSecretKey` and
/// `BlindKeyPair` declared in the files std's `crypto` namespace reaches through its own
/// relative imports (a declared set: each holds a private key), and each container those
/// files declare that holds one by value, as a field.
fn secretTypes(c: *Context) Context.Error![]const SecretType {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(SecretTypes);
    if (memo.built) return memo.types.items;
    memo.built = true;
    var roots: std.ArrayList(Project.FileId) = .empty;
    for (c.project.imports) |mapping| if (std.mem.eql(u8, mapping.spelling, "std")) {
        for (roots.items) |seen| {
            if (seen == mapping.target) break;
        } else try roots.append(c.allocator, mapping.target);
    };
    var files: std.ArrayList(Project.FileId) = .empty;
    for (roots.items) |root| {
        const crypto = c.facts.member(c.facts.rootOf(root), "crypto") orelse continue;
        // Its value, through any alias.
        const value = try c.facts.declaration(crypto);
        if (value != .container) continue;
        try files.append(c.allocator, value.container.file);
    }
    var next: usize = 0;
    while (next < files.items.len) : (next += 1) {
        const file = files.items[next];
        for (c.project.imports) |mapping| {
            if (mapping.from != file or !std.mem.endsWith(u8, mapping.spelling, ".zig")) continue;
            for (files.items) |seen| {
                if (seen == mapping.target) break;
            } else try files.append(c.allocator, mapping.target);
        }
    }
    const types = &memo.types;
    for (files.items) |file| for (c.project.at(file).model.declarations, 0..) |decl, d| {
        if (decl.kind != .variable or !decl.public) continue;
        for ([_][]const u8{ "SecretKey", "KeyPair", "BlindSecretKey", "BlindKeyPair" }) |name| if (std.mem.eql(u8, decl.name, name)) {
            const value = try c.facts.declaration(.{ .file = file, .index = @fromBackingInt(@intCast(d)) });
            if (value == .container) try types.append(c.allocator, .{ .container = value.container, .name = decl.name });
        };
    };
    // Each container of those files with a field of a secret type by value, until none is new.
    var grew = true;
    while (grew) {
        grew = false;
        for (files.items) |file| {
            const model = &c.project.at(file).model;
            for (model.declarations, 0..) |decl, d| {
                if (decl.kind != .field) continue;
                const container: Facts.Container = .{ .file = file, .scope = decl.scope };
                const known = for (types.items) |t| {
                    if (t.container.file == file and t.container.scope == decl.scope) break true;
                } else false;
                if (known or model.scopes[@backingInt(decl.scope)].kind != .container) continue;
                switch (try heldSecret(c, types.items, try c.facts.declaration(.{ .file = file, .index = @fromBackingInt(@intCast(d)) }))) {
                    .yes => |held| {
                        try types.append(c.allocator, .{ .container = container, .name = held });
                        grew = true;
                    },
                    .no, .unknown => {},
                }
            }
        }
    }
    return types.items;
}
const SecretTypes = struct { built: bool = false, types: std.ArrayList(SecretType) = .empty };

/// A011: time crossing to and from std as a raw integer.
pub fn units(c: *Context, rule: Rule) Context.Error!void {
    const doors = [_][]const u8{
        "Io.Duration.fromNanoseconds", "Io.Duration.fromMicroseconds", "Io.Duration.fromMilliseconds", "Io.Duration.fromSeconds",
        "Io.Duration.toNanoseconds",   "Io.Duration.toMicroseconds",   "Io.Duration.toMilliseconds",   "Io.Duration.toSeconds",
        "Io.Duration.nanoseconds",     "Io.Timestamp.fromNanoseconds", "Io.Timestamp.toNanoseconds",   "Io.Timestamp.toMicroseconds",
        "Io.Timestamp.toMilliseconds", "Io.Timestamp.toSeconds",       "Io.Timestamp.nanoseconds",
    };
    try rawTime(c, rule, &doors);
    const constants = [_][]const u8{
        "time.ns_per_us",  "time.ns_per_ms",   "time.ns_per_s",   "time.ns_per_min",  "time.ns_per_hour", "time.ns_per_day",  "time.ns_per_week",
        "time.us_per_ms",  "time.us_per_s",    "time.us_per_min", "time.us_per_hour", "time.us_per_day",  "time.us_per_week", "time.ms_per_s",
        "time.ms_per_min", "time.ms_per_hour", "time.ms_per_day", "time.ms_per_week", "time.s_per_min",   "time.s_per_hour",  "time.s_per_day",
        "time.s_per_week",
    };
    var targets: [constants.len]Governed.Target = undefined;
    var indexes: [constants.len]usize = undefined;
    for (constants, &targets, &indexes, 0..) |path, *target, *index, i| {
        target.* = .{ .source = "std", .declaration = path, .production = true };
        index.* = i;
    }
    const found = try Governed.resolve(c, rule, &targets, &indexes);
    var sites: std.ArrayList(Governed.Site) = .empty;
    try Governed.sites(c, rule, found, &sites);
    for (sites.items) |site| {
        // A unit converted by hand is one whether the program runs it or computes it as it
        // compiles, and wherever the constant goes (a local, an argument): each use is the site.
        // An alias the program declares is the site where it is made.
        if (site.through_alias or c.inTest(site.token)) continue;
        try c.at(rule, site.token, try c.allocator.print("std.{s}: a unit converted by hand; aegis units.Duration converts between units and checks the result", .{constants[site.index]}));
    }
}

/// A011's doors: each raw-integer crossing of std's time, as the program runs or compiles. Two
/// raw nanosecond counts compared or subtracted, or one compared with zero, keep their unit: no
/// conversion happens there.
fn rawTime(c: *Context, rule: Rule, paths: []const []const u8) Context.Error!void {
    const targets = try c.allocator.alloc(Governed.Target, paths.len);
    const indexes = try c.allocator.alloc(usize, paths.len);
    for (paths, targets, indexes, 0..) |path, *target, *index, i| {
        target.* = .{ .source = "std", .declaration = path, .production = true };
        index.* = i;
    }
    const found = try Governed.resolve(c, rule, targets, indexes);
    var sites: std.ArrayList(Governed.Site) = .empty;
    try Governed.sites(c, rule, found, &sites);
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    // The raw counts read out of std's time: what `sameUnit` compares, by meaning.
    var counts: std.ArrayList(Ast.Node.Index) = .empty;
    for (sites.items) |site| if (std.mem.endsWith(u8, paths[site.index], ".nanoseconds") and tree.nodeTag(site.node) == .field_access) try counts.append(c.allocator, site.node);
    for (sites.items) |site| {
        if (site.through_alias or c.inTest(site.token)) continue;
        if (sameUnit(tree, model, counts.items, site.node)) continue;
        try c.at(rule, site.token, try c.allocator.print("{s}: time as a raw integer; aegis units.Duration and Instant carry the unit and convert with toIoDuration and fromIoDuration", .{paths[site.index]}));
    }
    // A copy of memory between std's time and anything else, by what it does
    // (`Facts.accesses.copyAt`: `@memcpy(std.mem.asBytes(&d), std.mem.asBytes(&ns))`,
    // std.mem.copyForwards, `std.mem.bytesToValue(std.Io.Duration, bytes)`, a store through
    // `@ptrCast(&d)`), writes a raw count past the door, or reads one out of it; a copy of one
    // of its values into another is none. A side whose type does not resolve is undecided.
    var times: std.ArrayList(Facts.Container) = .empty;
    for (found) |g| if (std.mem.endsWith(u8, paths[g.index], ".nanoseconds")) for (g.decls) |decl| {
        try times.append(c.allocator, .{ .file = decl.file, .scope = c.project.at(decl.file).model.declarations[@backingInt(decl.index)].scope });
    };
    if (times.items.len == 0) return;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const copy = (try Facts.accesses.copyAt(c.facts, c.file, node)) orelse continue;
        const token = tree.nodeMainToken(node);
        if (c.inTest(token)) continue;
        const into = try heldTime(c, times.items, try c.facts.resolve(c.file, copy.into.node()));
        const from = try heldTime(c, times.items, try c.facts.resolve(c.file, copy.from.node()));
        if (into == from) continue;
        if (into == .unknown or from == .unknown) {
            try c.undecided(rule, tree.tokenStart(token), .unresolved, "a copy of memory one side of which does not resolve to a type may move std's time as a raw count");
            continue;
        }
        if (into == .yes) {
            try c.at(rule, token, "std's time written as raw bytes; aegis units.Duration and Instant carry the unit and convert with toIoDuration and fromIoDuration");
        } else try c.at(rule, token, "std's time read out as raw bytes; aegis units.Duration and Instant carry the unit and convert with toIoDuration and fromIoDuration");
    }
}

/// Whether a value is or holds by value one of std's time types (`times`): itself, an array's
/// elements, what a pointer or an optional holds, or a field of a struct or a union it is (a
/// record copied as bytes copies its fields; a pointer a field holds is no time by value). An
/// enum holds none; a container whose kind or fields do not resolve, or past sixteen levels,
/// may hold one.
const TimeHeld = enum { yes, no, unknown };
fn heldTime(c: *Context, times: []const Facts.Container, value: Facts.Value) Context.Error!TimeHeld {
    return timeHeld(c, times, value, true, 0);
}

fn timeHeld(c: *Context, times: []const Facts.Container, value: Facts.Value, side: bool, depth: u8) Context.Error!TimeHeld {
    if (depth >= 16) return .unknown;
    return switch (value) {
        .instance, .container => |found| blk: {
            for (times) |time| if (found.file == time.file and found.scope == time.scope) break :blk .yes;
            if (found.symbolic and found.made_by == null) break :blk .unknown;
            switch (c.facts.kindOf(found) orelse break :blk .unknown) {
                .keyword_enum => break :blk .no,
                .keyword_struct, .keyword_union => {},
                else => break :blk .unknown,
            }
            break :blk fieldsTime(c, times, try c.facts.heldFields(found), depth);
        },
        // The side of a copy is what its pointer points at; a pointer a record holds is its own.
        .pointer => |inner| if (side) timeHeld(c, times, inner.*, true, depth + 1) else .no,
        .array, .optional => |inner| timeHeld(c, times, inner.*, side, depth + 1),
        .alternatives => |each| blk: {
            var out: TimeHeld = .no;
            for (each) |one| switch (try timeHeld(c, times, one, side, depth + 1)) {
                .yes => out = .yes,
                .unknown => break :blk .unknown,
                .no => {},
            };
            break :blk out;
        },
        .primitive, .scalar => .no,
        else => .unknown,
    };
}

/// Whether the fields of a record hold a time by value: yes where one does, unknown where one
/// may.
fn fieldsTime(c: *Context, times: []const Facts.Container, fields: []const Facts.HeldField, depth: u8) Context.Error!TimeHeld {
    var out: TimeHeld = .no;
    for (fields) |field| switch (try timeHeld(c, times, field.value, false, depth + 1)) {
        .yes => return .yes,
        .unknown => out = .unknown,
        .no => {},
    };
    return out;
}

/// Whether a raw `.nanoseconds` read meets only another one, or zero, in a comparison or a
/// difference.
fn sameUnit(tree: *const Ast, model: anytype, counts: []const Ast.Node.Index, node: Ast.Node.Index) bool {
    if (!nanoseconds(tree, counts, node)) return false;
    var parent = model.parentOf(node) orelse return false;
    var at = node;
    // A difference of raw counts is one too: what it meets is what the read meets.
    while ((tree.nodeTag(parent) == .sub or tree.nodeTag(parent) == .sub_sat or tree.nodeTag(parent) == .grouped_expression) and nanoseconds(tree, counts, parent)) {
        at = parent;
        parent = model.parentOf(parent) orelse return false;
    }
    switch (tree.nodeTag(parent)) {
        .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal, .sub, .sub_sat => {},
        else => return false,
    }
    if (nanoseconds(tree, counts, parent)) return true;
    const lhs, const rhs = tree.nodeData(parent).node_and_node;
    const other = if (lhs == at) rhs else lhs;
    if (nanoseconds(tree, counts, other)) return true;
    return tree.nodeTag(other) == .number_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(other)), "0");
}

/// Whether a node is a raw nanosecond count: a read of std's `nanoseconds` (one of `counts`),
/// or a difference of two.
fn nanoseconds(tree: *const Ast, counts: []const Ast.Node.Index, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .field_access => std.mem.findScalar(Ast.Node.Index, counts, node) != null,
        .sub, .sub_sat => nanoseconds(tree, counts, tree.nodeData(node).node_and_node[0]) and nanoseconds(tree, counts, tree.nodeData(node).node_and_node[1]),
        .grouped_expression => nanoseconds(tree, counts, tree.nodeData(node).node_and_token[0]),
        else => false,
    };
}

/// A013: a contract a peer's input can reach: an `assert` whose condition holds input, an
/// `unreachable` on a branch input chooses, a `catch unreachable` or `orelse unreachable` on a
/// call that reads input or is given it. Input must meet an error, never a panic, or undefined
/// behaviour in a consumer's ReleaseFast build. An internal invariant no input reaches is the
/// program's to state, as Zig's own checks are; ReleaseFast is the consumer's choice.
pub fn contracts(c: *Context, rule: Rule) Context.Error!void {
    const flow = try Taint.get(c, peer_input);
    try asserts(c, rule, flow);
    const tree = &c.project.at(c.file).file.tree;
    var present: Present = try .init(c);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .unreachable_literal and tag != .unwrap_optional) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = if (tag == .unwrap_optional) tree.nodeData(node).node_and_token[1] else tree.nodeMainToken(node);
        if (c.inTest(token) or !atRuntime(c, node)) continue;
        // A `.?` of a value known not to be null never reaches its `unreachable`.
        if (tag == .unwrap_optional and try present.unwrapped(node)) continue;
        // `x.?` is `x orelse unreachable`: what makes `x` null chooses it too.
        const chosen = try chosenBy(c, flow, node);
        switch (if (tag == .unwrap_optional) chosen.join(try failedBy(c, flow, tree.nodeData(node).node_and_token[0])) else chosen) {
            .clean => {},
            .unknown => try c.undecided(rule, tree.tokenStart(token), .unresolved, "a branch that passed through a call that does not resolve may be input's to choose"),
            .data, .number => try c.at(rule, token, "unreachable on a path input chooses: a peer reaches a panic, or undefined behaviour in a consumer's ReleaseFast build; return an error"),
        }
    }
}

/// How far input chooses the path to `node`: the conditions of the branches and loops it is
/// in, the operands of the switches whose prongs hold it, and a `catch` or `orelse` it is the
/// answer of, through the call before it (what the call reads and is given), up to its
/// function.
fn chosenBy(c: *Context, flow: Taint.Fact, node: Ast.Node.Index) Context.Error!Taint.Level {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var out: Taint.Level = .clean;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .fn_decl => break,
            .@"catch", .@"orelse" => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (rhs == at) out = out.join(try failedBy(c, flow, lhs));
            },
            else => {},
        }
        if (tree.fullIf(parent)) |branch| {
            if (branch.ast.cond_expr != at) out = out.join(try Taint.conditionAt(c, flow, c.file, branch.ast.cond_expr));
        } else if (tree.fullWhile(parent)) |loop| {
            if (loop.ast.cond_expr != at) out = out.join(try Taint.conditionAt(c, flow, c.file, loop.ast.cond_expr));
        } else if (tree.fullSwitchCase(parent) != null) {
            const choice = model.parentOf(parent) orelse continue;
            const whole = tree.fullSwitch(choice) orelse continue;
            out = out.join(try Taint.levelAt(c, flow, c.file, whole.ast.condition));
        }
    }
    return out;
}

/// How far input can make `expression` fail: what it holds, and what a call it makes reads
/// and is given.
fn failedBy(c: *Context, flow: Taint.Fact, expression: Ast.Node.Index) Context.Error!Taint.Level {
    const tree = &c.project.at(c.file).file.tree;
    var out = try Taint.levelAt(c, flow, c.file, expression);
    var inner = expression;
    while (tree.nodeTag(inner) == .@"try" or tree.nodeTag(inner) == .grouped_expression) inner = if (tree.nodeTag(inner) == .@"try") tree.nodeData(inner).node else tree.nodeData(inner).node_and_token[0];
    const reached = (try Taint.reached(c, flow, c.file, inner)) orelse return out;
    for (reached.args) |arg| out = out.join(try Taint.levelAt(c, flow, c.file, arg));
    if (try Taint.isRead(c, flow, c.file, inner)) out = out.join(.data);
    return out;
}

/// A013's `std.debug.assert` sites whose condition holds input, each with its fix where the
/// file's code alone decides it: `std.debug.assert(c)`, or a call through a private alias,
/// becomes `aegis.assert.invariant(c, "c")`, the file importing aegis for it when it does not.
fn asserts(c: *Context, rule: Rule, flow: Taint.Fact) Context.Error!void {
    const message = "std.debug.assert on input: a contract a peer can break, a panic or undefined behaviour in a consumer's ReleaseFast build; return an error, or aegis assert.invariant checks it in every build";
    var target: [1]Governed.Target = .{.{ .source = "std", .declaration = "debug.assert", .production = true }};
    var index: [1]usize = .{0};
    const found = try Governed.resolve(c, rule, &target, &index);
    var sites: std.ArrayList(Governed.Site) = .empty;
    try Governed.sites(c, rule, found, &sites);
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var calls: std.ArrayList(Ast.Node.Index) = .empty;
    // A call through an alias the program declares is read by what its callee reaches.
    try aliasCalls(c, found[0].decls, &calls);
    for (sites.items) |site| {
        if (site.through_alias or c.inTest(site.token)) continue;
        const parent = model.parentOf(site.node) orelse continue;
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, parent)) |call| if (call.ast.fn_expr == site.node) {
            try calls.append(c.allocator, parent);
            continue;
        };
        // An alias's declaration is no call, nor is a constant pointer to it (`const check:
        // *const fn (bool) void = &std.debug.assert;`): `aliasCalls` reads the calls through
        // either. The assert taken as a value anywhere else (a field's default, a variable)
        // is called where it goes, which this reading does not follow, at run time or not.
        const held = if (tree.nodeTag(parent) == .address_of) model.parentOf(parent) orelse parent else parent;
        const value = if (held == parent) site.node else parent;
        if (tree.fullVarDecl(held)) |variable| if (variable.ast.init_node.unwrap() == value and tree.tokenTag(variable.ast.mut_token) == .keyword_const) continue;
        try c.undecided(rule, tree.tokenStart(site.token), .unresolved, "std.debug.assert taken as a value: its calls are not read");
    }
    for (calls.items) |node| {
        if (c.inTest(tree.nodeMainToken(node)) or !atRuntime(c, node)) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node).?;
        if (call.ast.params.len != 1) continue;
        const token = tree.firstToken(node);
        switch (try Taint.conditionAt(c, flow, c.file, call.ast.params[0])) {
            .clean => {},
            .unknown => try c.undecided(rule, tree.tokenStart(token), .unresolved, "a condition that passed through a call that does not resolve may hold input"),
            .data, .number => {
                var edits: std.ArrayList(Report.Edit) = .empty;
                if (try invariant(c, node, &edits)) try c.fixedAt(rule, token, message, edits.items) else try c.at(rule, token, message);
            },
        }
    }
}

/// The calls in this file through an alias the program declares of std's assert (`const check =
/// std.debug.assert;`), public or private, in any of its files, and an alias of one: each call
/// whose callee is a declaration other than std's that reaches one of `assert_decls`.
fn aliasCalls(c: *Context, assert_decls: []const Facts.Decl, calls: *std.ArrayList(Ast.Node.Index)) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        // A callee that does not resolve, or an alias whose value does not, is read by
        // `Governed.sites`: by its spelling, undecided where it may reach the assert.
        const callee = switch (try c.facts.definition(c.file, call.ast.fn_expr)) {
            .decl => |decl| decl,
            .none, .unknown => continue,
        };
        // std's assert called by its own name is a site `Governed.sites` gives.
        if (isAssert(assert_decls, callee)) continue;
        const reached: ?Facts.Decl = switch (try c.facts.origin(callee)) {
            .decl => |found| if (std.meta.eql(callee, found)) null else found,
            .none, .unknown => null,
        };
        // A constant pointer to it (`const check: *const fn (bool) void = &std.debug.assert;`,
        // a dependency's among them): each function the call may reach through it.
        const origins: []const Facts.Decl = if (reached) |found| &.{found} else switch ((try Facts.calls.at(c.facts, c.file, node) orelse continue).callee) {
            .function => |function| &.{function},
            .choice => |each| each,
            .any => continue,
        };
        for (origins) |one| if (isAssert(assert_decls, one)) {
            try calls.append(c.allocator, node);
            break;
        };
    }
}

fn isAssert(assert_decls: []const Facts.Decl, decl: Facts.Decl) bool {
    for (assert_decls) |each| if (std.meta.eql(each, decl)) return true;
    return false;
}

/// The edits that make the call at `node` (`f(c)`) `aegis.assert.invariant(c, "c")`, the
/// file's aegis import among them; false where the call is not that shape.
fn invariant(c: *Context, node: Ast.Node.Index, edits: *std.ArrayList(Report.Edit)) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (call.ast.params.len != 1) return false;
    const aegis = (try aegisName(c, edits)) orelse return false;
    const condition = tree.getNodeSource(call.ast.params[0]);
    var said: std.Io.Writer.Allocating = .init(c.allocator);
    // The message is the condition as written, on one line.
    var words = std.mem.tokenizeAny(u8, condition, " \t\r\n");
    var first = true;
    while (words.next()) |word| {
        // An allocating writer fails only when memory does.
        if (!first) said.writer.writeByte(' ') catch return error.OutOfMemory;
        std.zig.stringEscape(word, &said.writer) catch return error.OutOfMemory;
        first = false;
    }
    const start = tree.tokenStart(tree.firstToken(node));
    const last = tree.lastToken(node);
    try edits.append(c.allocator, .{ .start = start, .end = tree.tokenToSpan(last).end, .text = try c.allocator.print("{s}.assert.invariant({s}, \"{s}\")", .{ aegis, condition, said.written() }) });
    return true;
}

/// The name the file imports aegis by, an edit adding the import (after std's) when it has
/// none; null where `aegis` names something else.
fn aegisName(c: *Context, edits: *std.ArrayList(Report.Edit)) Context.Error!?[]const u8 {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const file = c.project.at(c.file).file;
    var after_std: u32 = 0;
    for (model.declarations) |decl| {
        if (decl.kind != .variable or model.scopes[@backingInt(decl.scope)].kind != .file) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        const spelled = tree.getNodeSource(init);
        if (std.mem.eql(u8, spelled, "@import(\"aegis\")")) return decl.name;
        if (std.mem.eql(u8, decl.name, "aegis")) return null;
        if (std.mem.eql(u8, spelled, "@import(\"std\")")) {
            const line = file.line(tree.tokenStart(decl.token));
            after_std = file.lineEnd(line);
        }
    }
    // With no std import the line goes after the file's doc comment, which stands first.
    if (after_std == 0) for (file.lines) |start| {
        if (!std.mem.startsWith(u8, file.source[start..], "//!")) {
            after_std = start;
            break;
        }
    };
    try edits.append(c.allocator, .{ .start = after_std, .end = after_std, .text = "const aegis = @import(\"aegis\");\n" });
    return "aegis";
}

/// A019: the operations Zig leaves unchecked.
pub fn unsafeSet(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        switch (tag) {
            .asm_simple, .@"asm" => {
                if (!c.inTest(token) and atRuntime(c, node)) try c.at(rule, token, "inline assembly: no check of what it reads or writes; keep it behind the package's one seam with its reason");
                continue;
            },
            else => {},
        }
        const name = Facts.builtinName(tree, node) orelse continue;
        if (c.inTest(token) or !atRuntime(c, node)) continue;
        if (std.mem.eql(u8, name, "@setRuntimeSafety")) {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 1) continue;
            const literal = if (tree.nodeTag(args[0]) == .identifier) tree.tokenSlice(tree.nodeMainToken(args[0])) else "";
            if (std.mem.eql(u8, literal, "false")) {
                try c.at(rule, token, "@setRuntimeSafety(false): bounds, overflow and union checks off; only a measured hot loop validated at its boundary");
                continue;
            }
            // A condition on the build mode: off in the modes whose checks it turns off. A mode
            // that builds without them (fast, small) loses nothing to it.
            const on = (try Model.modes(c.allocator, tree, &c.project.at(c.file).model, args[0], 0)) orelse {
                try c.unknown(rule, node, .comptime_dependent);
                continue;
            };
            var off: Model.Modes = .initMany(&.{ .debug, .safe });
            off.setIntersection(on.complement());
            var it = off.iterator();
            const first = it.next() orelse continue;
            const names = if (it.next() != null) "debug and safe" else @tagName(first);
            try c.at(rule, token, try c.allocator.print("@setRuntimeSafety off in {s} builds: bounds, overflow and union checks off where the build keeps them; only a measured hot loop validated at its boundary", .{names}));
            continue;
        }
        // An address read out of a pointer (`@intFromPtr`) is never undefined behavior. The
        // parent a field's pointer is taken to (`@fieldParentPtr`, std's reader and writer
        // pattern) is that parent only where the pointer is that field's, which no build checks,
        // and so is the alignment `@alignCast` asserts of it: a consumer may build the package
        // ReleaseFast, where nothing checks either.
        // Where the program shows the pointer is that field's (an interface's own field, a
        // node of an intrusive list), the parent is shown and its alignment with it.
        // A C handed to a generic whose body could not be read leaves it undecided; so does a
        // judgement the fact budget ran out in.
        const before = c.facts.remaining;
        var verdict: ParentPointer.Verdict = if (std.mem.eql(u8, name, "@fieldParentPtr"))
            try ParentPointer.cleared(c, node)
        else if (std.mem.eql(u8, name, "@alignCast")) try ParentPointer.clearedAlignment(c, node) else .open;
        if (verdict == .open and before != 0 and c.facts.remaining == 0) verdict = .undecided;
        switch (verdict) {
            .shown => continue,
            .undecided => {
                try c.undecided(rule, tree.tokenStart(token), .unsupported, "a parent pointer whose parent is handed to a generic that is not read to its end: a copy of the field there is not ruled out");
                continue;
            },
            .open => {},
        }
        for ([_][]const u8{ "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@ptrFromInt", "@fieldParentPtr" }) |cast| if (std.mem.eql(u8, name, cast)) {
            try c.at(rule, token, try c.allocator.print("{s}: a pointer conversion no build checks", .{name}));
        };
    }
    // The interface contract: what may break a parent pointer an interface recovers.
    try ParentPointer.contract(c, rule);
    const model = &c.project.at(c.file).model;
    for (model.declarations) |decl| {
        if (decl.kind != .variable and decl.kind != .function) continue;
        const token: ?Ast.TokenIndex = if (decl.kind == .function) blk: {
            var buffer: [1]Ast.Node.Index = undefined;
            break :blk (tree.fullFnProto(&buffer, decl.node) orelse continue).extern_export_inline_token;
        } else (tree.fullVarDecl(decl.node) orelse continue).extern_export_token;
        const keyword = token orelse continue;
        if (tree.tokenTag(keyword) != .keyword_extern or c.inTest(decl.token)) continue;
        try c.at(rule, keyword, try c.allocator.print("extern '{s}': a declaration whose definition Zig does not check; only the raw call, at the package's seam", .{decl.name}));
    }
}

/// A014's frame escapes (Escapes.zig).
pub fn lifetimes(c: *Context, rule: Rule) Context.Error!void {
    try Escapes.check(c, rule);
}

/// A007's synchronization types: each place the program holds one (a field, a variable, a
/// value it makes), never a pointer that borrows one held elsewhere or a member named through
/// the type (`Io.Event.Error`). The held sites' tokens, for the variables they type, with every
/// site's token and the declarations, for the types named under other names.
fn governedHeld(c: *Context, rule: Rule, paths: []const []const u8, comptime message: []const u8) Context.Error!Held {
    const targets = try c.allocator.alloc(Governed.Target, paths.len);
    const indexes = try c.allocator.alloc(usize, paths.len);
    for (paths, targets, indexes, 0..) |path, *target, *index, i| {
        target.* = .{ .source = "std", .declaration = path, .production = true };
        index.* = i;
    }
    const found = try Governed.resolve(c, rule, targets, indexes);
    var sites: std.ArrayList(Governed.Site) = .empty;
    var unread: std.ArrayList(Governed.Unread) = .empty;
    try Governed.sitesLeaving(c, rule, found, &sites, &unread);
    var held: std.ArrayList(Ast.TokenIndex) = .empty;
    var spelled: std.ArrayList(Ast.TokenIndex) = .empty;
    for (sites.items) |site| {
        // A pointer's site borrows: a value read through it (`@as(*Value, p).*`) is judged
        // by what it holds.
        if (try borrowed(c, site.node)) continue;
        try spelled.append(c.allocator, site.token);
        if (site.through_alias or c.inTest(site.token)) continue;
        try held.append(c.allocator, site.token);
        try c.at(rule, site.token, try c.allocator.print(message, .{paths[site.index]}));
    }
    return .{ .tokens = held.items, .named = spelled.items, .unread = unread.items, .found = found };
}

const Held = struct {
    tokens: []const Ast.TokenIndex,
    /// Every site spelling a governed name but a pointer's, held or not: each is judged by that
    /// name.
    named: []const Ast.TokenIndex,
    /// Each reference spelling a governed name that does not resolve: undecided, but where it
    /// types a value `heldUnderOtherNames` judges, which is judged there.
    unread: []const Governed.Unread,
    found: []const Governed.Governed,
};

/// A synchronization type held by value under any name: a variable, a parameter, a capture or
/// a field whose value, by meaning, is one of std's (a dependency's `pub const Lock =
/// std.Io.Mutex`, a value a call, a `try`, a branch, a destructure or `@call` gives), past
/// arrays, optionals and error unions, or a function's result that is one. One whose own
/// declaration holds a governed site reported there is judged by that site. A value that does not resolve is
/// undecided: it may be one. The held tokens, with `found`'s.
fn heldUnderOtherNames(c: *Context, rule: Rule, paths: []const []const u8, found: Held, comptime message: []const u8) Context.Error![]const Ast.TokenIndex {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var held: std.ArrayList(Ast.TokenIndex) = .empty;
    try held.appendSlice(c.allocator, found.tokens);
    const judged = try c.allocator.alloc(bool, found.unread.len);
    @memset(judged, false);
    for (model.declarations, 0..) |decl, d| {
        if (c.inTest(decl.token)) continue;
        // A block's local or a capture that exists only as the program compiles holds no lock.
        if ((decl.kind == .capture or (decl.kind == .variable and model.scopes[@backingInt(decl.scope)].kind != .file and model.scopes[@backingInt(decl.scope)].kind != .container)) and !atRuntime(c, decl.node)) continue;
        const at: Facts.Decl = .{ .file = c.file, .index = @fromBackingInt(@intCast(d)) };
        const value: Facts.Value = switch (decl.kind) {
            .variable, .parameter, .field => blk: {
                // One whose declaration spells a governed name is judged at that site.
                if (within(tree, found.tokens, decl.node) or within(tree, found.named, decl.node)) continue;
                // A module or file `@import` gives: a namespace, a type, which holds no state.
                if (decl.kind == .variable) if (tree.fullVarDecl(decl.node)) |variable| if (variable.ast.init_node.unwrap()) |init| if (imported(tree, init)) continue;
                // Typed by a declaration of this file whose own site is reported (the program's
                // alias of a lock): judged there.
                if (namesHeld(tree, model, decl.node, found.tokens)) continue;
                break :blk try c.facts.declaration(at);
            },
            .capture => try c.facts.declaration(at),
            .function => blk: {
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, decl.node) orelse continue;
                const result = proto.ast.return_type.unwrap() orelse continue;
                if (within(tree, found.tokens, result)) continue;
                break :blk try c.facts.callResult(.{ .function = at }, {});
            },
        };
        // A reference that does not resolve as this value's type, or what an array, an optional,
        // an error union or a pointer of it holds, is judged with the value.
        if (writtenType(tree, model, decl)) |written| for (found.unread, judged) |each, *done| {
            if (typeSpine(tree, written, each.node)) done.* = true;
        };
        switch (try heldSync(c, found.found, value)) {
            .no => {},
            .unknown => |why| {
                if (bindingsJudge(c, why, decl.node) or (why == .comptime_dependent and !runtimeState(c, decl))) continue;
                // A variable given only enum literals holds an enum's tag (or a union's with no
                // payload): no synchronization (`const w: std.meta.Tag(V) = .a`). Not where one
                // names a member of a synchronization type: a decl literal (`.init`) makes one,
                // and `std.Io.Event` is an enum.
                if (decl.kind == .variable) if (tree.fullVarDecl(decl.node)) |variable| if (variable.ast.init_node.unwrap()) |init| if (enumLiterals(tree, init) and !try namesSyncMember(c, found.found, init)) continue;
                try c.undecided(rule, tree.tokenStart(decl.token), .unresolved, "a value whose type does not resolve may hold std's synchronization");
            },
            .yes => |index| {
                try held.append(c.allocator, decl.token);
                try c.at(rule, decl.token, try c.allocator.print(message, .{paths[index]}));
            },
        }
    }
    for (found.unread, judged) |each, done| if (!done) try c.unknown(rule, each.node, each.why);
    return held.items;
}

/// The type a declaration is written with: a variable's, a field's or a parameter's, a
/// function's result. Null for a capture, or one written with none.
fn writtenType(tree: *const Ast, model: *const Model, decl: Model.Declaration) ?Ast.Node.Index {
    return switch (decl.kind) {
        .variable => (tree.fullVarDecl(decl.node) orelse return null).ast.type_node.unwrap(),
        .field => (model.containerField(tree, decl.node) orelse return null).ast.type_expr.unwrap(),
        // A parameter's node is its type, or its function's where it is written with none.
        .parameter => blk: {
            var buffer: [1]Ast.Node.Index = undefined;
            break :blk if (tree.fullFnProto(&buffer, decl.node) == null) decl.node else null;
        },
        .function => blk: {
            var buffer: [1]Ast.Node.Index = undefined;
            break :blk (tree.fullFnProto(&buffer, decl.node) orelse return null).ast.return_type.unwrap();
        },
        else => null,
    };
}

/// Whether `reference` is the type `written`, or what an array, an optional, an error union's
/// payload or a pointer of it holds: what `heldSync` reads a value of the type through.
fn typeSpine(tree: *const Ast, written: Ast.Node.Index, reference: Ast.Node.Index) bool {
    var at = written;
    while (at != reference) at = switch (tree.nodeTag(at)) {
        .grouped_expression => tree.nodeData(at).node_and_token[0],
        .optional_type => tree.nodeData(at).node,
        .error_union => tree.nodeData(at).node_and_node[1],
        .array_type => tree.nodeData(at).node_and_node[1],
        .array_type_sentinel => tree.nodeData(at).node_and_extra[0],
        else => (tree.fullPtrType(at) orelse return false).ast.child_type,
    };
    return true;
}

const Sync = union(enum) { yes: usize, no, unknown: Facts.Unknown };

/// Whether a value holds one of std's synchronization types by value: an instance of one
/// (`syncType`), an array, an optional or an error union of one, or a choice one of whose
/// values is. A pointer borrows it; a type, a number, a function hold none; any other value is
/// unknown (`Facts.resolve`'s contract).
fn heldSync(c: *Context, found: []const Governed.Governed, value: Facts.Value) Context.Error!Sync {
    switch (value) {
        .instance => |inner| {
            if (try syncType(c, found, .{ .container = inner })) |index| return .{ .yes = index };
            // aegis's types hold std's synchronization as their internals.
            if (try c.inLibrary(Contract.library, inner.file)) return .no;
            var out: Sync = .no;
            for (try unjudgedFields(c, inner)) |field| switch (try heldSync(c, found, field)) {
                .yes => |index| return .{ .yes = index },
                .unknown => |why| out = .{ .unknown = why },
                .no => {},
            };
            return out;
        },
        .array, .optional, .error_union => |inner| return heldSync(c, found, inner.*),
        // A tuple or struct literal with no type of its own holds each part by value; a part
        // known only as the program compiles (an enum literal, `.{ "pointer", .pointer }`, or
        // one of a choice of such tuples) leaves it so, as such a declaration is.
        .alternatives, .literal => {
            const each = if (value == .literal) try c.facts.literalParts(value.literal) else value.alternatives;
            var out: Sync = .no;
            for (each, 0..) |one, i| switch (if (value == .literal and enumLiteralPart(c, value.literal, i)) .no else try heldSync(c, found, one)) {
                .yes => |index| return .{ .yes = index },
                .unknown => |why| if (why != .comptime_dependent) {
                    out = .{ .unknown = .unresolved };
                } else if (out == .no) {
                    out = .{ .unknown = why };
                },
                .no => {},
            };
            return out;
        },
        // A type built from its fields' types (`@Struct`): a value of it holds each.
        .reified => |built| return if (built.value) heldSync(c, found, try c.facts.reifiedParts(built)) else .no,
        .pointer, .container, .primitive, .scalar, .function, .fn_type, .error_set => return .no,
        .unknown => |why| return .{ .unknown = why },
        else => return .{ .unknown = .unsupported },
    }
}

/// Whether every value an expression can give is an enum literal (`.a`, `if (x) .a else .b`, a
/// `switch` each prong of which gives one).
fn enumLiterals(tree: *const Ast, node: Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .enum_literal => return true,
        .grouped_expression => return enumLiterals(tree, tree.nodeData(node).node_and_token[0]),
        .@"switch", .switch_comma => {
            const full = tree.fullSwitch(node).?; // unreachable: tagged a switch
            for (full.ast.cases) |case| if (!enumLiterals(tree, tree.fullSwitchCase(case).?.ast.target_expr)) return false; // unreachable: a switch's cases are cases
            return full.ast.cases.len != 0;
        },
        else => {
            const branch = tree.fullIf(node) orelse return false;
            const otherwise = branch.ast.else_expr.unwrap() orelse return false;
            return enumLiterals(tree, branch.ast.then_expr) and enumLiterals(tree, otherwise);
        },
    }
}

/// Whether an enum literal `node` gives (`enumLiterals`' shapes) names a declaration or a tag
/// of one of std's synchronization types, or of the type a governed type function makes.
fn namesSyncMember(c: *Context, found: []const Governed.Governed, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    switch (tree.nodeTag(node)) {
        .enum_literal => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            for (found) |g| for (g.decls) |decl| {
                const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
                const held = if (record.kind == .function) try c.facts.template(decl) orelse continue else try c.facts.declaration(decl);
                const container = switch (held) {
                    .container => |each| each,
                    else => continue,
                };
                if (c.facts.member(container, name) != null or c.facts.declaresTag(container, name)) return true;
            };
            return false;
        },
        .grouped_expression => return namesSyncMember(c, found, tree.nodeData(node).node_and_token[0]),
        .@"switch", .switch_comma => {
            for (tree.fullSwitch(node).?.ast.cases) |case| if (try namesSyncMember(c, found, tree.fullSwitchCase(case).?.ast.target_expr)) return true; // unreachable: tagged a switch, whose cases are cases
            return false;
        },
        else => {
            const branch = tree.fullIf(node) orelse return false;
            if (try namesSyncMember(c, found, branch.ast.then_expr)) return true;
            return namesSyncMember(c, found, branch.ast.else_expr.unwrap() orelse return false);
        },
    }
}

/// The index of the governed synchronization type `value` is, a type by value: a container
/// one of `found` declares, or one a governed function makes (its scope lies in the
/// function's body), past arrays, optionals and error unions, or any alternative that is one.
fn syncType(c: *Context, found: []const Governed.Governed, value: Facts.Value) Context.Error!?usize {
    switch (value) {
        .array, .optional, .error_union => |inner| return syncType(c, found, inner.*),
        .alternatives => |each| {
            for (each) |one| if (try syncType(c, found, one)) |index| return index;
        },
        .container => |held| for (found) |g| for (g.decls) |decl| {
            const model = &c.project.at(decl.file).model;
            const record = model.declarations[@backingInt(decl.index)];
            if (record.kind == .function) {
                if (held.file != decl.file) continue;
                // The declaration's node is its prototype; its body ends the `fn` around it.
                const tree = &c.project.at(decl.file).file.tree;
                const whole = model.parentOf(record.node) orelse record.node;
                const scope = model.scopes[@backingInt(held.scope)];
                if (scope.first >= tree.firstToken(whole) and scope.last <= tree.lastToken(whole)) return g.index;
            } else switch (try c.facts.declaration(decl)) {
                .container => |sync| if (sync.file == held.file and sync.scope == held.scope) return g.index,
                else => {},
            }
        },
        else => {},
    }
    return null;
}

/// Whether a type named at `node` stands behind a pointer, names a member of the type that is
/// no value of it (a function, a type: `Io.Event.Error`), or is only compared (`T ==
/// std.Io.Mutex`, a comptime check that refuses the type): none holds one. A member that is a
/// value (`std.Io.Mutex.init`) is one held.
fn borrowed(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    if (model.parentOf(node)) |parent| {
        if (tree.nodeTag(parent) == .field_access and tree.nodeData(parent).node_and_token[0] == node) return switch (try c.facts.resolve(c.file, parent)) {
            .function, .container, .error_set, .primitive, .fn_type => true,
            else => false,
        };
        // The type itself, or what its constructor makes (`std.atomic.Value(u32)`), compared.
        var compared = parent;
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, parent)) |made| if (made.ast.fn_expr == node) {
            compared = model.parentOf(parent) orelse parent;
        };
        if (tree.nodeTag(compared) == .equal_equal or tree.nodeTag(compared) == .bang_equal) return true;
    }
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => return true,
            .fn_decl, .block, .block_semicolon, .block_two, .block_two_semicolon => return false,
            else => {},
        }
        if (tree.fullVarDecl(parent) != null or model.containerField(tree, parent) != null) return false;
    }
    return false;
}

/// Whether one of `tokens` lies in `node`.
/// Whether `node` is an `@import`.
fn imported(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import"),
        else => false,
    };
}

/// Whether the type a declaration at `node` writes names a declaration of this file that holds
/// one of `tokens`.
fn namesHeld(tree: *const Ast, model: *const Model, node: Ast.Node.Index, tokens: []const Ast.TokenIndex) bool {
    const written: Ast.Node.Index = if (model.containerField(tree, node)) |field|
        field.ast.type_expr.unwrap() orelse return false
    else if (tree.fullVarDecl(node)) |variable|
        variable.ast.type_node.unwrap() orelse return false
    else
        node;
    const first = tree.firstToken(written);
    const last = tree.lastToken(written);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const named: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(named);
        if (token < first or token > last) continue;
        const index = (model.reference(named) orelse continue).declaration orelse continue;
        if (within(tree, tokens, model.declarations[@backingInt(index)].node)) return true;
    }
    return false;
}

fn within(tree: *const Ast, tokens: []const Ast.TokenIndex, node: Ast.Node.Index) bool {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    for (tokens) |token| if (token >= first and token <= last) return true;
    return false;
}

/// Each site in production code that reaches one of std's `paths`, past an alias the program
/// declares (its value is the site), reported with `message` naming the path. An operation
/// (`operation`: a call, a conversion) is a site only where it runs with the program; a type is
/// the program's state wherever it is named.
fn governed(c: *Context, rule: Rule, paths: []const []const u8, operation: bool, comptime message: []const u8) Context.Error!void {
    const targets = try c.allocator.alloc(Governed.Target, paths.len);
    const indexes = try c.allocator.alloc(usize, paths.len);
    for (paths, targets, indexes, 0..) |path, *target, *index, i| {
        target.* = .{ .source = "std", .declaration = path, .production = true };
        index.* = i;
    }
    const found = try Governed.resolve(c, rule, targets, indexes);
    var sites: std.ArrayList(Governed.Site) = .empty;
    try Governed.sites(c, rule, found, &sites);
    for (sites.items) |site| {
        if (site.through_alias or c.inTest(site.token)) continue;
        // An operation is judged where it runs, or where a container's declaration names it
        // (`const eql = std.crypto.timing_safe.eql;`): the program takes it up there, whether
        // it calls it or binds it into a generic's context, whose call runs in that generic.
        if (operation and !atRuntime(c, site.node) and !declaredAs(c, site.node)) continue;
        try c.at(rule, site.token, try c.allocator.print(message, .{paths[site.index]}));
    }
}

/// Whether a reference is the whole value of a constant a file or container declares.
fn declaredAs(c: *const Context, node: Ast.Node.Index) bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const parent = model.parentOf(node) orelse return false;
    const variable = tree.fullVarDecl(parent) orelse return false;
    if (variable.ast.init_node.unwrap() != node) return false;
    const holder = model.parentOf(parent) orelse return true;
    var buffer: [2]Ast.Node.Index = undefined;
    return tree.fullContainerDecl(&buffer, holder) != null or tree.nodeTag(holder) == .root;
}

/// Whether the code at `node` runs when the program runs: inside a function's body that does
/// not return `type`, outside any `comptime` block and any container's declarations nested
/// there. A container-level value or a field's default is evaluated as the program compiles.
pub fn atRuntime(c: *const Context, node: Ast.Node.Index) bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .@"comptime" => return false,
            .test_decl => return true,
            .fn_decl => {
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, tree.nodeData(parent).node_and_node[0]) orelse return true;
                const result = proto.ast.return_type.unwrap() orelse return true;
                return !(tree.nodeTag(result) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(result)), "type"));
            },
            else => {
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullContainerDecl(&buffer, parent) != null) return false;
            },
        }
    }
    return false;
}
