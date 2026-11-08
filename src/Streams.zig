//! A020's lost cancel (designs/aegis.md §7): std's streams that keep the cause of their failure,
//! `Io.File.Reader`, `Io.net.Stream.Reader`, `Io.File.Writer` and `Io.net.Stream.Writer`. An
//! operation on one fails with `ReadFailed` or `WriteFailed` and leaves the cause on its `err`,
//! `error.Canceled` among it when the task was canceled inside the operation. Each operation is
//! judged by one question: does a cancel inside it reach the caller as `error.Canceled`?
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Range = @import("Range.zig");
const accesses = Facts.accesses;
const formAt = Range.formAt;
const nameRef = Range.nameRef;
const spellsName = Range.spellsName;
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Program = @import("Program.zig");
const Danger = @import("Danger.zig");
const Governed = @import("Governed.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;

const paths = [_][]const u8{ "Io.File.Reader", "Io.net.Stream.Reader", "Io.File.Writer", "Io.net.Stream.Writer" };

/// The streams by their containers, in `paths`' order (null where std declares none), and
/// whether std's declarations of them could not all be read: then any value may be one.
const Kinds = struct {
    each: [paths.len]?Facts.Container = @splat(null),
    /// `Io.Reader` and `Io.Writer`, the readers' and the writers' `interface`.
    interfaces: [2]?Facts.Container = @splat(null),
    unknown: bool = false,
};

/// A stream's type: one of `paths`, or one that does not resolve.
const Kind = union(enum) { known: usize, unresolved };

fn kinds(c: *Context) Context.Error!Kinds {
    var out: Kinds = .{};
    for (paths, &out.each) |path, *slot| {
        const decls = switch (try Governed.declarations(c, "std", path)) {
            .decls => |decls| decls,
            .none => continue,
            .unknown => {
                out.unknown = true;
                continue;
            },
        };
        slot.* = try container(c, decls, &out.unknown);
    }
    // Where either interface is not known, no method names a side (`sideOf`).
    var unread = false;
    for ([_][]const u8{ "Io.Reader", "Io.Writer" }, &out.interfaces) |path, *slot| switch (try Governed.declarations(c, "std", path)) {
        .decls => |decls| slot.* = try container(c, decls, &unread),
        .none, .unknown => {},
    };
    if (unread) out.interfaces = @splat(null);
    return out;
}

/// The container std's `decls` declare, by their origin; `unknown` set where one does not resolve.
fn container(c: *Context, decls: []const Facts.Decl, unknown: *bool) Context.Error!?Facts.Container {
    var found: ?Facts.Container = null;
    for (decls) |decl| {
        const origin = switch (try c.facts.origin(decl)) {
            .decl => |at| at,
            .none => decl,
            .unknown => {
                unknown.* = true;
                continue;
            },
        };
        const value = try c.facts.declaration(origin);
        if (value == .container) found = value.container;
    }
    return found;
}

/// The error an operation on a stream of `kind` fails with, its cause on `err`.
fn failure(kind: usize) []const u8 {
    return if (kind < 2) "ReadFailed" else "WriteFailed";
}

/// Which of the streams `node`'s value is, a pointer to one read the same; null where it is
/// none of them.
fn kindOf(c: *Context, ks: *const Kinds, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Kind {
    var value = try c.facts.resolve(file, node);
    if (value == .pointer) value = value.pointer.child.*;
    const held = switch (value) {
        .instance, .container => |k| k,
        .unknown => return .unresolved,
        // A choice is the one stream every part is; parts of two kinds, or a part not known, may
        // be either; parts none of which is a stream, none.
        .alternatives => |parts| {
            var found: ?Kind = null;
            for (parts) |part| {
                const one = (try kindOfValue(ks, part)) orelse continue;
                if (one == .unresolved) return .unresolved;
                if (found) |known| if (!std.meta.eql(known, one)) return .unresolved;
                found = one;
            }
            return found;
        },
        else => return null,
    };
    for (ks.each, 0..) |each, at| {
        const k = each orelse continue;
        if (k.file == held.file and k.scope == held.scope) return .{ .known = at };
    }
    return if (ks.unknown) .unresolved else null;
}

/// `kindOf` of one part of a choice.
fn kindOfValue(ks: *const Kinds, given: Facts.Value) Context.Error!?Kind {
    var value = given;
    if (value == .pointer) value = value.pointer.child.*;
    const held = switch (value) {
        .instance, .container => |k| k,
        .unknown, .alternatives => return .unresolved,
        else => return null,
    };
    for (ks.each, 0..) |each, at| {
        const k = each orelse continue;
        if (k.file == held.file and k.scope == held.scope) return .{ .known = at };
    }
    return if (ks.unknown) .unresolved else null;
}

/// Whether the member read `node` is the field `name` its holder's own type declares (a
/// stream's `interface`, a reader's `err`), by declaration: null where `node` is no member read
/// or its holder's type does not resolve.
fn ownField(c: *Context, file: Project.FileId, node: Ast.Node.Index, name: []const u8) Context.Error!?bool {
    const tree = &c.project.at(file).file.tree;
    if (formAt(tree, node) != .member) return false;
    var value = try c.facts.resolve(file, tree.nodeData(node).node_and_token[0]);
    while (value == .pointer) value = value.pointer.child.*;
    const holder = switch (value) {
        .instance, .container => |k| k,
        // A holder chosen per build: its field is not one known.
        .alternatives => return null,
        else => return null,
    };
    const declared = c.facts.member(holder, name) orelse return false;
    return switch (try c.facts.definition(file, node)) {
        .decl => |found| std.meta.eql(found, declared),
        .none => false,
        .unknown => null,
    };
}

/// Whether the member read `node` is the field `name` of the stream its holder is (`ownField`),
/// and where the holder's type does not resolve (a generic's local, a choice per build), whether
/// it is so for every stream it may be: if the holder is one of std's streams, Zig resolves the
/// name it spells in that stream's type, so the access is `name` where, in each stream type that
/// declares the spelled name, it is the declaration of `name`. A holder that may be no stream, or
/// streams whose declarations std's could not all be read, is none.
fn streamField(c: *Context, ks: *const Kinds, file: Project.FileId, node: Ast.Node.Index, name: []const u8) Context.Error!bool {
    if (try ownField(c, file, node, name)) |own| return own;
    if (ks.unknown) return false;
    const step = (try Facts.accesses.memberRead(c.facts, file, node)) orelse return false;
    const spelled = step.name orelse return false;
    if (try kindOf(c, ks, file, step.receiver.?) == null) return false; // unreachable: a member's step has its holder
    var any = false;
    for (ks.each) |each| {
        const k = each orelse continue;
        // A stream type with no such name: Zig would not compile the access on one.
        const named = c.facts.member(k, spelled) orelse continue;
        const declared = c.facts.member(k, name) orelse return false;
        if (!std.meta.eql(named, declared)) return false;
        any = true;
    }
    return any;
}

/// A place a stream is named by: a declaration and the fields read from it (`self.source`),
/// with the node naming the place after each step (`nodes[0]` the root's). An alias
/// (`const in = &r.interface`, `const p = &r`) names the place it points at, and a wrapper made
/// over a stream's interface (`r.interface.limited(...)`, an init given `&r.interface`) the
/// stream it wraps: its operations fail with that stream's failure, the cause on that stream's
/// `err`.
const Place = struct {
    file: Project.FileId,
    root: Model.Declaration.Id,
    names: [max][]const u8 = undefined,
    nodes: [max + 1]Ast.Node.Index = undefined,
    len: u8 = 0,

    const max = 8;

    fn node(p: *const Place) Ast.Node.Index {
        return p.nodes[p.len];
    }

    fn last(p: *const Place) ?[]const u8 {
        return if (p.len == 0) null else p.names[p.len - 1];
    }

    fn parent(p: Place) Place {
        var q = p;
        q.len -= 1;
        return q;
    }

    fn same(a: *const Place, b: *const Place) bool {
        if (a.file != b.file or a.root != b.root or a.len != b.len) return false;
        for (a.names[0..a.len], b.names[0..b.len]) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }

    /// Whether `a` is `b` or a place `b` reaches by its fields.
    fn prefix(a: *const Place, b: *const Place) bool {
        if (a.file != b.file or a.root != b.root or a.len > b.len) return false;
        for (a.names[0..a.len], b.names[0..a.len]) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }
};

fn placeOf(c: *Context, ks: *const Kinds, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!?Place {
    if (depth >= 8) return null;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    switch (formAt(tree, node)) {
        .grouped => return placeOf(c, ks, file, tree.nodeData(node).node_and_token[0], depth + 1),
        .address_of, .deref => return placeOf(c, ks, file, tree.nodeData(node).node, depth + 1),
        .member => {
            const object, const name = tree.nodeData(node).node_and_token;
            var p = (try placeOf(c, ks, file, object, depth + 1)) orelse return null;
            if (p.len == Place.max) return null;
            p.names[p.len] = tree.tokenSlice(name);
            p.len += 1;
            p.nodes[p.len] = node;
            return p;
        },
        .leaf => {
            const id = (nameRef(model, node) orelse return null).declaration orelse return null;
            const record = model.declarations[@backingInt(id)];
            if (record.kind == .variable) if (tree.fullVarDecl(record.node)) |variable| if (variable.ast.init_node.unwrap()) |init| {
                // A constant pointer to a place is that place.
                if (tree.tokenTag(variable.ast.mut_token) == .keyword_const and formAt(tree, init) == .address_of) {
                    if (try placeOf(c, ks, file, init, depth + 1)) |p| return p;
                }
                if (try wrapped(c, ks, file, node, init, depth)) |p| return p;
            };
            var p: Place = .{ .file = file, .root = id };
            p.nodes[0] = node;
            return p;
        },
        else => return null,
    }
}

/// The stream a local wraps: its value has an `interface` of its own and is made by a call on a
/// stream's interface or given one (`r.interface.limited(...)`, `.init(&r.interface, ...)`).
fn wrapped(c: *Context, ks: *const Kinds, file: Project.FileId, local: Ast.Node.Index, init: Ast.Node.Index, depth: u8) Context.Error!?Place {
    switch (try c.facts.resolve(file, local)) {
        .instance, .container => |k| if (c.facts.member(k, "interface") == null) return null,
        // A wrapper chosen per build is no one stream's.
        .alternatives => return null,
        else => return null,
    }
    if (try kindOf(c, ks, file, local) != null) return null;
    const call = (try Facts.calls.at(c.facts, file, init)) orelse return null;
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => return null,
    };
    for (args) |operand| {
        if (!try interface(c, file, operand)) continue;
        const p = (try placeOf(c, ks, file, operand, depth + 1)) orelse continue;
        return p.parent();
    }
    return null;
}

/// Whether `node` (or what it points at) is `x.interface`.
fn interface(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    return (try ownField(c, file, interfaceRead(&c.project.at(file).file.tree, node), "interface")) orelse false;
}

/// The member read under `&` and parentheses (`&r.interface`).
fn interfaceRead(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = node;
    while (true) switch (formAt(tree, at)) {
        .address_of => at = tree.nodeData(at).node,
        .grouped => at = tree.nodeData(at).node_and_token[0],
        else => return at,
    };
}

/// An operation a call makes on a stream: the stream's place (null where it is reached by what
/// no place names, `rs[i].interface`) and node, and its kind.
const Operation = struct {
    place: ?Place,
    stream: Ast.Node.Index,
    file: Project.FileId,
    kind: Kind,
    /// For a stream whose type does not resolve, the kind whose failure it is where the method
    /// called on its `interface` is only a reader's or only a writer's (0 or 2).
    side: ?usize = null,
};

/// The operations a call makes: through a stream's `interface` (as receiver, `r.interface.take()`,
/// or handed, `&r.interface`), by a method of the stream's own type whose error set may hold its
/// failure (`r.seekBy(n)`), or by handing the stream to a function that may (a std one by its
/// error set, the program's where it reads or writes it and lets the failure go without its
/// `err`, `lets`, one that does not resolve as it may).
fn operations(c: *Context, ks: *const Kinds, file: Project.FileId, call: *const Facts.calls.Call, depth: u8) Context.Error![]const Operation {
    const tree = &c.project.at(file).file.tree;
    var out: std.ArrayList(Operation) = .empty;
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => return unknownArgs(c, ks, file, call),
    };
    // What it passes, the receiver first, in the callee's parameter order (Facts.calls).
    for (args, 0..) |operand, position| {
        if (try interface(c, file, operand)) {
            // By its place, a wrapper read as the stream it wraps; else by the expression.
            if (try placeOf(c, ks, file, operand, 0)) |p| {
                const stream = p.parent();
                const kind = (try kindOf(c, ks, stream.file, stream.node())) orelse continue;
                try out.append(c.allocator, .{ .place = stream, .stream = stream.node(), .file = stream.file, .kind = kind });
            } else {
                const stream = tree.nodeData(interfaceRead(tree, operand)).node_and_token[0];
                const kind = (try kindOf(c, ks, file, stream)) orelse continue;
                try out.append(c.allocator, .{ .place = null, .stream = stream, .file = file, .kind = kind });
            }
            continue;
        }
        // A wrapper, or an alias of an interface, read as its stream.
        if (try placeOf(c, ks, file, operand, 0)) |p| if (p.len > 0 and (try ownField(c, p.file, p.node(), "interface") orelse false) and p.root != rootOf(c, file, operand)) {
            const stream = p.parent();
            const kind = (try kindOf(c, ks, file, stream.node())) orelse continue;
            try out.append(c.allocator, .{ .place = stream, .stream = stream.node(), .file = p.file, .kind = kind });
            continue;
        };
        // An operand whose type does not resolve may be a stream of either kind.
        const kind = (try kindOf(c, ks, file, operand)) orelse continue;
        const p = try placeOf(c, ks, file, operand, 0);
        // Each function it may call; one it may call but does not know may fail.
        const choices: []const Facts.Decl = switch (call.callee) {
            .function => |*decl| decl[0..1],
            .choice => |each| each,
            .any => &.{},
        };
        const fails = call.callee == .any or for (choices) |choice| {
            // One whose origin does not resolve may be either.
            const callee = switch (try c.facts.origin(choice)) {
                .decl => |found| found,
                .none => choice,
                .unknown => break true,
            };
            // An operand not known to be a stream is one only where the parameter may hold one.
            if (kind == .unresolved and !try mayHold(c, ks, callee, position)) continue;
            if (try Program.owns(c, callee.file)) {
                if (try lets(c, ks, callee, position, depth)) break true;
            } else switch (kind) {
                .known => |k| if (try mayFail(c, callee, failure(k))) break true,
                .unresolved => if (try mayFail(c, callee, failure(0)) or try mayFail(c, callee, failure(2))) break true,
            }
        } else false;
        if (!fails) continue;
        try out.append(c.allocator, .{ .place = p, .stream = operand, .file = file, .kind = kind });
    }
    return out.items;
}

/// The operations of a call whose arguments Facts.calls does not know (a method on a holder whose
/// type does not resolve, `@call` given no tuple literal): a method on an `interface` is one on
/// what holds it, its failure by the method's (`sideOf`); else each operand as written, a value
/// receiver first, that is or may be a stream. Where the operands are not written, any may be.
fn unknownArgs(c: *Context, ks: *const Kinds, file: Project.FileId, call: *const Facts.calls.Call) Context.Error![]const Operation {
    const tree = &c.project.at(file).file.tree;
    var out: std.ArrayList(Operation) = .empty;
    var receiver: ?Ast.Node.Index = null;
    if (formAt(tree, call.callee_expr) == .member) {
        const holder, const method = tree.nodeData(call.callee_expr).node_and_token;
        if (formAt(tree, holder) == .member and try interface(c, file, holder)) {
            const stream = tree.nodeData(holder).node_and_token[0];
            const kind = (try kindOf(c, ks, file, stream)) orelse return &.{};
            try out.append(c.allocator, .{ .place = try placeOf(c, ks, file, stream, 0), .stream = stream, .file = file, .kind = kind, .side = sideOf(c, ks, tree.tokenSlice(method)) });
            return out.items;
        }
        // A type's function binds no receiver.
        if (try c.facts.resolve(file, holder) != .container) receiver = holder;
    }
    var buffer: [1]Ast.Node.Index = undefined;
    const written = tree.fullCall(&buffer, call.node) orelse {
        try out.append(c.allocator, .{ .place = null, .stream = call.node, .file = file, .kind = .unresolved });
        return out.items;
    };
    if (receiver) |operand| try unknownOperand(c, ks, file, operand, &out);
    for (written.ast.params) |operand| try unknownOperand(c, ks, file, operand, &out);
    return out.items;
}

/// `operand` as an operation of a call whose callee's parameters are not known, where it is or
/// may be a stream: the callee may operate on it.
fn unknownOperand(c: *Context, ks: *const Kinds, file: Project.FileId, operand: Ast.Node.Index, out: *std.ArrayList(Operation)) Context.Error!void {
    const tree = &c.project.at(file).file.tree;
    // A literal of a tag, a number, a string or a character holds no stream.
    if (try c.facts.literalOf(file, operand)) |written| switch (written) {
        .enum_literal, .number, .string, .char => return,
        else => {},
    };
    const stream = if (try interface(c, file, operand)) tree.nodeData(interfaceRead(tree, operand)).node_and_token[0] else operand;
    const kind = (try kindOf(c, ks, file, stream)) orelse return;
    try out.append(c.allocator, .{ .place = try placeOf(c, ks, file, stream, 0), .stream = stream, .file = file, .kind = kind });
}

/// Which kind's failure a method named `method` on a stream's `interface` has: a reader's where
/// only `Io.Reader` declares it, a writer's where only `Io.Writer` does; null where both or
/// neither do, or either is not known.
fn sideOf(c: *Context, ks: *const Kinds, method: []const u8) ?usize {
    const reader = ks.interfaces[0] orelse return null;
    const writer = ks.interfaces[1] orelse return null;
    const reads = c.facts.member(reader, method) != null;
    const writes = c.facts.member(writer, method) != null;
    if (reads == writes) return null;
    return if (reads) 0 else 2;
}

/// The declaration the expression `node`'s place begins at, where one does.
fn rootOf(c: *Context, file: Project.FileId, node: Ast.Node.Index) ?Model.Declaration.Id {
    const tree = &c.project.at(file).file.tree;
    var at = node;
    while (true) at = switch (formAt(tree, at)) {
        .grouped, .member => tree.nodeData(at).node_and_token[0],
        .address_of, .deref => tree.nodeData(at).node,
        .leaf => return ((nameRef(&c.project.at(file).model, at) orelse return null).declaration),
        else => return null,
    };
}

/// Whether std's `callee` may fail with `name`: its declared error set names it, or is one this
/// does not follow.
fn mayFail(c: *Context, callee: Facts.Decl, name: []const u8) Context.Error!bool {
    const tree = &c.project.at(callee.file).file.tree;
    const model = &c.project.at(callee.file).model;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(callee.index)].node) orelse return true;
    const result = proto.ast.return_type.unwrap() orelse return true;
    if (formAt(tree, result) != .error_union) {
        const before = tree.firstToken(result);
        // `!T`: what it returns is inferred.
        return before > 0 and tree.tokenTag(before - 1) == .bang;
    }
    return names(c, callee.file, tree.nodeData(result).node_and_node[0], name, 0);
}

/// Whether the error set `node` may hold `name`.
fn names(c: *Context, file: Project.FileId, node: Ast.Node.Index, name: []const u8, depth: u8) Context.Error!bool {
    if (depth >= 8) return true;
    const tree = &c.project.at(file).file.tree;
    switch (formAt(tree, node)) {
        .grouped => return names(c, file, tree.nodeData(node).node_and_token[0], name, depth + 1),
        .merged_errors => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return try names(c, file, lhs, name, depth + 1) or try names(c, file, rhs, name, depth + 1);
        },
        .leaf, .member => {
            // `error{A, B}`: its names, each a global identity; a name, the set it names.
            if (formAt(tree, node) == .leaf and !spellsName(tree, node)) {
                if (tree.tokenTag(tree.nodeMainToken(node)) != .keyword_error) return true;
                var token = tree.nodeMainToken(node) + 2;
                while (token < tree.lastToken(node)) : (token += 1) {
                    if (tree.tokenTag(token) == .identifier and std.mem.eql(u8, tree.tokenSlice(token), name)) return true;
                }
                return false;
            }
            const decl = switch (try c.facts.definition(file, node)) {
                .decl => |found| found,
                .none, .unknown => return true,
            };
            const target = &c.project.at(decl.file).file.tree;
            const variable = target.fullVarDecl(c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return true;
            return names(c, decl.file, variable.ast.init_node.unwrap() orelse return true, name, depth + 1);
        },
        else => return true,
    }
}

/// Whether the program's `callee`, handed a stream as its parameter at `position`, may let a
/// failure of it go without its `err`: one of its operations on that stream passes the failure on,
/// maps or drops it, or keeps it. One that does not resolve may.
fn lets(c: *Context, ks: *const Kinds, callee: Facts.Decl, position: usize, depth: u8) Context.Error!bool {
    if (depth >= 4) return true;
    const tree = &c.project.at(callee.file).file.tree;
    const model = &c.project.at(callee.file).model;
    const param = parameterAt(c, callee, position) orelse return true;
    const function = model.parentOf(model.declarations[@backingInt(callee.index)].node) orelse return true;
    if (tree.nodeTag(function) != .fn_decl) return true;
    const body = tree.nodeData(function).node_and_node[1];
    for (try Facts.calls.in(c.facts, callee.file)) |call| {
        if (tree.nodeMainToken(call.node) < tree.firstToken(body) or tree.nodeMainToken(call.node) > tree.lastToken(body)) continue;
        for (try operations(c, ks, callee.file, &call, depth + 1)) |op| {
            const p = op.place orelse return true;
            if (p.root != param or p.len != 0) continue;
            switch (try handling(c, ks, callee.file, call.node, op, depth + 1)) {
                .cleared, .discarded => {},
                else => return true,
            }
        }
    }
    return false;
}

/// The declaration of `function`'s parameter at `position`.
/// Whether `function`'s parameter at `position` may hold a stream: `anytype`, a type that does not
/// resolve, or one of the streams (by value, pointer or optional); not a type that resolves to
/// anything else (`std.builtin.Endian`, an integer, `type`).
fn mayHold(c: *Context, ks: *const Kinds, function: Facts.Decl, position: usize) Context.Error!bool {
    const tree = &c.project.at(function.file).file.tree;
    const model = &c.project.at(function.file).model;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(function.index)].node) orelse return true;
    var params = proto.iterate(tree);
    var at: usize = 0;
    const param = while (params.next()) |param| : (at += 1) {
        if (at == position) break param;
    } else return true;
    const type_expr = param.type_expr orelse return true;
    var value = try c.facts.resolve(function.file, type_expr);
    while (true) value = switch (value) {
        .pointer => |inner| inner.child.*,
        .optional => |inner| inner.*,
        .alternatives => break,
        else => break,
    };
    const held = switch (value) {
        .unknown => return true,
        .container, .instance => |k| k,
        // A parameter whose type is chosen per build may hold a stream where any part may.
        .alternatives => |parts| {
            for (parts) |part| if (try kindOfValue(ks, part) != null) return true;
            return false;
        },
        else => return false,
    };
    if (ks.unknown) return true;
    for (ks.each) |each| {
        const k = each orelse continue;
        if (k.file == held.file and k.scope == held.scope) return true;
    }
    return false;
}

fn parameterAt(c: *Context, function: Facts.Decl, position: usize) ?Model.Declaration.Id {
    const tree = &c.project.at(function.file).file.tree;
    const model = &c.project.at(function.file).model;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(function.index)].node) orelse return null;
    var params = proto.iterate(tree);
    var at: usize = 0;
    const name = while (params.next()) |param| : (at += 1) {
        if (at == position) break param.name_token orelse return null;
    } else return null;
    for (model.declarations, 0..) |decl, i| {
        if (decl.kind == .parameter and decl.token == name) return @fromBackingInt(@intCast(i));
    }
    return null;
}

/// What becomes of an operation's failure: its cause reaches the caller (`cleared`), the failure
/// is passed on without it (`try`, returned as it is), mapped or dropped by a handler that does
/// not pass the cause on, or kept as an error union. A call whose value is discarded (a
/// statement, a loop's body) gives none: Zig discards no error union, so it fails nothing; an
/// `if`'s branch is read where the `if`'s value goes.
const Handling = enum { cleared, passed, mapped, kept, discarded };

fn handling(c: *Context, ks: *const Kinds, file: Project.FileId, call: Ast.Node.Index, op: Operation, depth: u8) Context.Error!Handling {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    // A stream of either kind is cleared only where both failures are.
    const kind = switch (op.kind) {
        .known => |k| k,
        .unresolved => {
            if (op.side) |side| {
                var one = op;
                one.kind = .{ .known = side };
                return handling(c, ks, file, call, one, depth);
            }
            var read = op;
            read.kind = .{ .known = 0 };
            var write = op;
            write.kind = .{ .known = 2 };
            const r = try handling(c, ks, file, call, read, depth);
            return if (r == .cleared) handling(c, ks, file, call, write, depth) else r;
        },
    };
    var at = call;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (formAt(tree, parent)) {
            .grouped => continue,
            .tried, .@"return" => return .passed,
            .@"catch" => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (lhs != at) return .kept;
                const catch_token = tree.nodeMainToken(parent);
                const capture: ?Ast.TokenIndex = if (tree.tokenTag(catch_token + 1) == .pipe) catch_token + 2 else null;
                return if (try clears(c, ks, file, parent, rhs, capture, op, kind, depth)) .cleared else .mapped;
            },
            else => {
                if (tree.fullIf(parent)) |branch| {
                    if (branch.ast.cond_expr == at and branch.error_token != null) {
                        return if (try clears(c, ks, file, parent, branch.ast.else_expr.unwrap() orelse return .mapped, branch.error_token, op, kind, depth)) .cleared else .mapped;
                    }
                    // A branch's value is the `if`'s: read where that goes.
                    if (branch.ast.cond_expr != at) continue;
                }
                if (tree.fullWhile(parent)) |loop| {
                    if (loop.ast.cond_expr == at and loop.error_token != null) {
                        return if (try clears(c, ks, file, parent, loop.ast.else_expr.unwrap() orelse return .mapped, loop.error_token, op, kind, depth)) .cleared else .mapped;
                    }
                    if (loop.ast.cond_expr != at) return .discarded;
                }
                if (tree.fullFor(parent)) |loop| if (loop.ast.then_expr == at) return .discarded;
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.blockStatements(&buffer, parent) != null) return .discarded;
                return .kept;
            },
        }
    }
    return .kept;
}

/// Whether a handler passes the cause of the failure it catches on: on a switch on the caught
/// error, each prong that takes the failure (one naming it, else `else`); otherwise the whole
/// handler. A path clears where every way it leaves gives the stream's cause (`clearsPath`).
fn clears(c: *Context, ks: *const Kinds, file: Project.FileId, whole: Ast.Node.Index, handler: Ast.Node.Index, capture: ?Ast.TokenIndex, op: Operation, kind: usize, depth: u8) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const stream = op.place orelse return false;
    var h = handler;
    h = Facts.ungrouped(tree, h);
    var returned = false;
    if (tree.nodeTag(h) == .@"return") if (tree.nodeData(h).opt_node.unwrap()) |value| if (tree.fullSwitch(value) != null) {
        h = value;
        returned = true;
    };
    if (capture) |name| if (tree.fullSwitch(h)) |chosen| if (spellsName(tree, chosen.ast.condition) and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(chosen.ast.condition)), tree.tokenSlice(name))) {
        var otherwise: ?Ast.Node.Index = null;
        var named = false;
        for (chosen.ast.cases) |case_node| {
            const case = tree.fullSwitchCase(case_node).?; // unreachable: a switch's cases are cases
            if (case.ast.values.len == 0) otherwise = case.ast.target_expr;
            for (case.ast.values) |value| if (errorNamed(tree, value, failure(kind))) {
                named = true;
                if (!try clearsPath(c, ks, file, whole, case.ast.target_expr, &stream, returned, depth)) return false;
            };
        }
        if (named) return true;
        return clearsPath(c, ks, file, whole, otherwise orelse return true, &stream, returned, depth);
    };
    return clearsPath(c, ks, file, whole, h, &stream, returned, depth);
}

/// Whether `node` is `error.<name>`.
fn errorNamed(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    // An error name is a global identity: `error.<name>` by its token.
    return formAt(tree, node) == .leaf and tree.tokenTag(tree.nodeMainToken(node)) == .keyword_error and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node) + 2), name);
}

/// Whether every way a handler's path leaves gives the stream's cause: each `return` before a
/// guard that returns a cancel (`guards`), and the path's value where the whole (the `catch` or
/// `if`) is returned or tried. A block that may end without leaving drops the failure.
fn clearsPath(c: *Context, ks: *const Kinds, file: Project.FileId, whole: Ast.Node.Index, path: Ast.Node.Index, stream: *const Place, returned: bool, depth: u8) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, path)) |statements| {
        const lbrace = tree.nodeMainToken(path);
        if (lbrace >= 2 and tree.tokenTag(lbrace - 1) == .colon) return false;
        for (statements) |statement| {
            if (try guards(c, ks, file, statement, stream, depth)) return true;
            if (!try returnsCause(c, ks, file, statement, stream, depth)) return false;
        }
        if (statements.len == 0) return false;
        const end = statements[statements.len - 1];
        return tree.nodeTag(end) == .@"return" or tree.nodeTag(end) == .unreachable_literal;
    }
    if (tree.nodeTag(path) == .@"return" or tree.nodeTag(path) == .unreachable_literal) return cause(c, ks, file, path, stream, depth);
    if (!returned and !leaves(c, file, whole)) return false;
    return cause(c, ks, file, path, stream, depth);
}

/// Whether the whole a handler belongs to is returned or tried: its value goes to the caller.
fn leaves(c: *Context, file: Project.FileId, whole: Ast.Node.Index) bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = whole;
    while (model.parentOf(at)) |parent| : (at = parent) switch (formAt(tree, parent)) {
        .grouped => {},
        .tried, .@"return" => return true,
        else => return false,
    };
    return false;
}

/// Whether every `return` in `statement` gives the stream's cause, but one where the stream
/// holds none (on the right of `s.err orelse`, an `if (s.err) |e|`'s `else`).
fn returnsCause(c: *Context, ks: *const Kinds, file: Project.FileId, statement: Ast.Node.Index, stream: *const Place, depth: u8) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeMainToken(node) < tree.firstToken(statement) or tree.nodeMainToken(node) > tree.lastToken(statement)) continue;
        if (try causeless(c, ks, file, node, statement, stream)) continue;
        if (!try cause(c, ks, file, node, stream, depth)) return false;
    }
    return true;
}

/// Whether `node` is reached only where the stream holds no cause: on the right of an
/// `s.err orelse`, or in the `else` of an `if (s.err) |e|`, within `outer`.
fn causeless(c: *Context, ks: *const Kinds, file: Project.FileId, node: Ast.Node.Index, outer: Ast.Node.Index, stream: *const Place) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .@"orelse") {
            const lhs, const rhs = tree.nodeData(parent).node_and_node;
            if (rhs == at and try isErr(c, ks, file, lhs, stream)) return true;
        }
        if (tree.fullIf(parent)) |branch| if (branch.ast.else_expr.unwrap() == at and branch.payload_token != null and try isErr(c, ks, file, branch.ast.cond_expr, stream)) return true;
        if (parent == outer) return false;
    }
    return false;
}

/// Whether `place`'s expression is the stream's `err`.
fn isErr(c: *Context, ks: *const Kinds, file: Project.FileId, node: Ast.Node.Index, stream: *const Place) Context.Error!bool {
    const p = (try placeOf(c, ks, file, node, 0)) orelse return false;
    // The stream's own `err`, by the declaration its type gives the name.
    if (p.len == 0 or !try streamField(c, ks, p.file, p.node(), "err")) return false;
    const holder = p.parent();
    return holder.same(stream);
}

/// Whether a statement is a guard that returns a cancel before anything else may leave:
/// `if (s.err) |e| return e;`, `if (s.err) |e| if (e == error.Canceled) return e;`, a switch on
/// the cause whose `Canceled` prong returns it, or `if (s.err == error.Canceled) return ...`.
fn guards(c: *Context, ks: *const Kinds, file: Project.FileId, statement: Ast.Node.Index, stream: *const Place, depth: u8) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const branch = tree.fullIf(statement) orelse {
        if (tree.fullSwitch(statement)) |chosen| if (try causeOf(c, ks, file, chosen.ast.condition, stream)) {
            const prong = canceledProng(tree, chosen) orelse return false;
            return tree.nodeTag(prong) == .@"return" and try cause(c, ks, file, prong, stream, depth);
        };
        return false;
    };
    if (branch.payload_token != null and try isErr(c, ks, file, branch.ast.cond_expr, stream)) {
        // Its first statement returns the cause, or guards: what follows never sees a cancel.
        var then = branch.ast.then_expr;
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.blockStatements(&buffer, then)) |statements| {
            if (statements.len == 0) return false;
            then = statements[0];
        }
        if (tree.nodeTag(then) == .@"return") return cause(c, ks, file, then, stream, depth);
        return guards(c, ks, file, then, stream, depth);
    }
    // `e == error.Canceled` of a cause, or `s.err == error.Canceled`.
    const condition = branch.ast.cond_expr;
    if (tree.nodeTag(condition) != .equal_equal) return false;
    const lhs, const rhs = tree.nodeData(condition).node_and_node;
    const named = if (errorNamed(tree, rhs, "Canceled")) lhs else if (errorNamed(tree, lhs, "Canceled")) rhs else return false;
    if (!try causeOf(c, ks, file, named, stream)) return false;
    var then = branch.ast.then_expr;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, then)) |statements| {
        if (statements.len != 1) return false;
        then = statements[0];
    }
    return tree.nodeTag(then) == .@"return" and try cause(c, ks, file, then, stream, depth);
}

/// The prong a switch takes for `error.Canceled`: one naming it, else `else`.
fn canceledProng(tree: *const Ast, chosen: Ast.full.Switch) ?Ast.Node.Index {
    var otherwise: ?Ast.Node.Index = null;
    for (chosen.ast.cases) |case_node| {
        const case = tree.fullSwitchCase(case_node).?; // unreachable: a switch's cases are cases
        if (case.ast.values.len == 0) otherwise = case.ast.target_expr;
        for (case.ast.values) |value| if (errorNamed(tree, value, "Canceled")) return case.ast.target_expr;
    }
    return otherwise;
}

/// Whether `node` holds the stream's cause: `s.err`, `s.err.?`, `s.err orelse v`, a capture of
/// one (`if (s.err) |e|`, a prong's of a switch on one) or a constant made from one.
fn causeOf(c: *Context, ks: *const Kinds, file: Project.FileId, node: Ast.Node.Index, stream: *const Place) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    switch (formAt(tree, node)) {
        .grouped, .unwrap_optional => return causeOf(c, ks, file, tree.nodeData(node).node_and_token[0], stream),
        .@"orelse" => return causeOf(c, ks, file, tree.nodeData(node).node_and_node[0], stream),
        .member => return isErr(c, ks, file, node, stream),
        .leaf => {
            const id = (nameRef(model, node) orelse return false).declaration orelse return false;
            const record = model.declarations[@backingInt(id)];
            switch (record.kind) {
                .capture => return causeOf(c, ks, file, c.facts.captureSource(file, record) orelse return false, stream),
                .variable => {
                    const variable = tree.fullVarDecl(record.node) orelse return false;
                    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
                    return causeOf(c, ks, file, variable.ast.init_node.unwrap() orelse return false, stream);
                },
                else => return false,
            }
        },
        else => return false,
    }
}

/// Whether a value gives the caller the stream's cause on a cancel: the cause itself
/// (`causeOf`), `error.Canceled`, a switch on the cause whose `Canceled` prong gives it, both
/// ways of an `if`, every prong of another switch, a call of the program's function handed the
/// stream whose every return gives its cause (`helperCause`), or no value (`unreachable`).
fn cause(c: *Context, ks: *const Kinds, file: Project.FileId, node: Ast.Node.Index, stream: *const Place, depth: u8) Context.Error!bool {
    if (depth >= 8) return false;
    const tree = &c.project.at(file).file.tree;
    switch (formAt(tree, node)) {
        .grouped => return cause(c, ks, file, tree.nodeData(node).node_and_token[0], stream, depth),
        .@"return" => return cause(c, ks, file, tree.nodeData(node).opt_node.unwrap() orelse return false, stream, depth),
        .leaf => switch (tree.tokenTag(tree.nodeMainToken(node))) {
            .keyword_unreachable => return true,
            .keyword_error => return errorNamed(tree, node, "Canceled"),
            else => if (spellsName(tree, node)) return causeOf(c, ks, file, node, stream),
        },
        .unwrap_optional, .@"orelse", .member => return causeOf(c, ks, file, node, stream),
        .builtin => {
            // `@errorCast(e)`, `@as(E, e)`.
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            if (std.mem.eql(u8, name, "@errorCast") and args.len == 1) return cause(c, ks, file, args[0], stream, depth + 1);
            if (std.mem.eql(u8, name, "@as") and args.len == 2) return cause(c, ks, file, args[1], stream, depth + 1);
            return false;
        },
        else => {},
    }
    if (tree.fullIf(node)) |branch| {
        const otherwise = branch.ast.else_expr.unwrap() orelse return false;
        return try cause(c, ks, file, branch.ast.then_expr, stream, depth + 1) and try cause(c, ks, file, otherwise, stream, depth + 1);
    }
    if (tree.fullSwitch(node)) |chosen| {
        if (try causeOf(c, ks, file, chosen.ast.condition, stream)) {
            const prong = canceledProng(tree, chosen) orelse return false;
            if (spellsName(tree, prong)) if (prongCapture(tree, chosen, prong)) return true;
            return cause(c, ks, file, prong, stream, depth + 1);
        }
        for (chosen.ast.cases) |case_node| if (!try cause(c, ks, file, tree.fullSwitchCase(case_node).?.ast.target_expr, stream, depth + 1)) return false;
        return true;
    }
    if (try Facts.calls.at(c.facts, file, node)) |call| return helperCause(c, ks, file, call, stream, depth + 1);
    return false;
}

/// Whether `value` is the capture of the prong whose value it is (`else => |e| e`).
fn prongCapture(tree: *const Ast, chosen: Ast.full.Switch, value: Ast.Node.Index) bool {
    for (chosen.ast.cases) |case_node| {
        const case = tree.fullSwitchCase(case_node).?; // unreachable: a switch's cases are cases
        if (case.ast.target_expr != value) continue;
        const payload = case.payload_token orelse return false;
        return std.mem.eql(u8, tree.tokenSlice(payload), tree.tokenSlice(tree.nodeMainToken(value)));
    }
    return false;
}

/// Whether a call of the program's function, handed the stream or a place that holds it (its
/// receiver among them: `self.readFault()` for `self.source`), returns the stream's cause on every
/// way it returns but where the stream holds none (`causeless`).
fn helperCause(c: *Context, ks: *const Kinds, file: Project.FileId, call: Facts.calls.Call, stream: *const Place, depth: u8) Context.Error!bool {
    const callee = switch (call.callee) {
        .function => |decl| switch (try c.facts.origin(decl)) {
            .decl => |found| found,
            .none => decl,
            .unknown => return false,
        },
        else => return false,
    };
    if (!try Program.owns(c, callee.file)) return false;
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => return false,
    };
    for (args, 0..) |operand, position| {
        const held = (try placeOf(c, ks, file, operand, 0)) orelse continue;
        if (!held.prefix(stream)) continue;
        const param = parameterAt(c, callee, position) orelse return false;
        var inner: Place = .{ .file = callee.file, .root = param, .len = stream.len - held.len };
        @memcpy(inner.names[0..inner.len], stream.names[held.len..stream.len]);
        const target = &c.project.at(callee.file).file.tree;
        const model = &c.project.at(callee.file).model;
        const function = model.parentOf(model.declarations[@backingInt(callee.index)].node) orelse return false;
        if (target.nodeTag(function) != .fn_decl) return false;
        const body = target.nodeData(function).node_and_node[1];
        var any = false;
        for (target.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .@"return") continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (target.nodeMainToken(node) < target.firstToken(body) or target.nodeMainToken(node) > target.lastToken(body)) continue;
            if (try causeless(c, ks, callee.file, node, body, &inner)) continue;
            if (!try cause(c, ks, callee.file, node, &inner, depth)) return false;
            any = true;
        }
        return any;
    }
    return false;
}

/// A020: each operation on a std stream whose failure's cause, a cancel among it, does not reach
/// the caller. A stream the function makes (a local, or a field of one) is a finding: no caller
/// can ask it what failed. One it is given (a parameter) is its caller's to ask, as std's
/// convention has it. One held in a field or a global, or reached by what no place names, is
/// undecided: who else can ask it is not followed. A local stream whose type does not resolve,
/// or an error union kept for later, is undecided.
pub fn lost(c: *Context, rule: Rule) Context.Error!void {
    const ks = try kinds(c);
    const any = ks.unknown or for (ks.each) |k| {
        if (k != null) break true;
    } else false;
    if (!any) return;
    const tree = &c.project.at(c.file).file.tree;
    for (try Facts.calls.in(c.facts, c.file)) |call| {
        const node = call.node;
        if (c.inTest(tree.nodeMainToken(node)) or !Danger.atRuntime(c, node)) continue;
        // An operation gives an error union; `r.interface.limited(...)` makes a reader. A choice
        // of results gives one where any of them may (a generic called with two stream types).
        const result = try c.facts.resolve(c.file, node);
        var gives: Facts.Join = .{};
        for (Facts.valueParts(&result)) |part| gives.add(part, part == .error_union);
        if (gives.any() == false) continue;
        for (try operations(c, &ks, c.file, &call, 0)) |op| {
            // One it is given is its caller's to ask, whatever its type or handling.
            const origin = try originOf(c, op);
            if (origin == .given) continue;
            const how = try handling(c, &ks, c.file, node, op, 0);
            switch (how) {
                .cleared, .discarded => continue,
                .kept => {
                    try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "an operation on a std stream whose error union is kept for later: whether its failure's cause is asked of the stream's err is not followed");
                    break;
                },
                .passed, .mapped => {},
            }
            if (origin != .made or op.kind == .unresolved) {
                try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, if (op.kind == .unresolved) "an operation on what may be a std stream (a holder, an argument or a call whose type does not resolve), its failure passed on, mapped or dropped without its err: if it is one, a cancel inside it is lost" else "an operation on a std stream held in a field or a global whose failure is passed on, mapped or dropped without its err: whoever else may ask it what failed is not followed, and a cancel inside it may be lost");
                break;
            }
            const kind = op.kind.known;
            const name = tree.getNodeSource(op.stream);
            try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("{s} std.{s} this function makes whose error.{s} is {s} without its err: a cancel inside it is on {s}.err, and no caller can ask it, so the cancel is lost; on error.{s} return {s}.err (error.Canceled among it)", .{ if (kind < 2) "a read of a" else "a write to a", paths[kind], failure(kind), if (how == .passed) "passed on" else "mapped or dropped", name, failure(kind), name }));
            break;
        }
    }
}

/// Whose stream an operation is: one the function makes (a local by value, or a field of one),
/// one it is given (a parameter itself), or one held elsewhere.
fn originOf(c: *Context, op: Operation) Context.Error!enum { made, given, held } {
    const p = op.place orelse return .held;
    const model = &c.project.at(p.file).model;
    const record = model.declarations[@backingInt(p.root)];
    switch (record.kind) {
        .parameter => return if (p.len == 0) .given else .held,
        .variable => {
            switch (model.scopes[@backingInt(record.scope)].kind) {
                .file, .container => return .held,
                else => {},
            }
            // A local pointer holds what another made.
            return if (try c.facts.resolve(p.file, p.nodes[0]) == .pointer) .held else .made;
        },
        else => return .held,
    }
}

/// Whether a call is a cancellation point by its streams: an operation on one whose failure's
/// cause reaches the caller (a read whose `ReadFailed` returns `r.err`, `error.Canceled` among
/// it, is cancelable as `Io`'s own operations are).
pub fn point(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const ks = try kinds(c);
    const call = (try Facts.calls.at(c.facts, file, node)) orelse return false;
    for (try operations(c, &ks, file, &call, 0)) |op| {
        if (op.kind != .known) continue;
        if (try handling(c, &ks, file, node, op, 0) == .cleared) return true;
    }
    return false;
}
