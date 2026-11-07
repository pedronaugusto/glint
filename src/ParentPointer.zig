//! Where A019 clears a parent pointer: a `@fieldParentPtr("F", p)` the program shows is taken
//! from a pointer to field F of a C, and the `@alignCast` around it, which then asserts C's
//! own alignment. Two shapes, each shown across the package (docs/design.md lists both):
//!
//! An interface field. F's type is the type `p` points at, `p` being the converting
//! function's parameter: std's `Io.Reader` or `Io.Writer`, or an interface struct of the
//! program's own. The function is not `pub`, in C's file, and every reference to it installs it
//! into C.F of a value that is a C, directly or through constants that are not `pub` (a vtable,
//! a struct holding one) each referenced only so in turn; or it is a helper only such functions
//! call on their own interface parameter. Every use of C.F in the package takes its address, reads a part of it, or calls a
//! method that takes it by pointer: a copy of it would carry the function to a pointer that is
//! no C's field.
//!
//! An intrusive list node. F's type is std's `DoublyLinkedList.Node` or `SinglyLinkedList.Node`;
//! `p` is `&c.F` of a C, or a node out of one list (its `first`, `last`, `popFirst()`,
//! `popLast()`, a node's `next` or `prev` out of the same list). Every insertion into a list that
//! may be that one, anywhere in the package, inserts `&c.F` of a C, and C.F is never copied.
//!
//! Anything glint cannot show of these is no parent pointer cleared: the finding stands.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Governed = @import("Governed.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;

/// Whether the `@fieldParentPtr` call `node` in the checked file is one of the two shapes,
/// with every generic a C is handed to read: shown, or undecided where one could not be.
pub fn cleared(c: *Context, node: Ast.Node.Index) Context.Error!Verdict {
    const field, const kind, const interface = (try shown(c, node)) orelse return .open;
    return generics(c, field, kind, interface);
}

/// The field a conversion is of, and its type, where it is one of the two shapes.
fn shown(c: *Context, node: Ast.Node.Index) Context.Error!?struct { Field, Facts.Container, bool } {
    const tree = &c.project.at(c.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 2) return null;
    // The one name it spells (`Facts.fieldName`).
    const name = switch (try c.facts.fieldName(c.file, args[0])) {
        .name => |name| name,
        .each_of, .names, .computed => return null,
    };
    const parent = pointee(try resultType(c, c.file, node)) orelse return null;
    const field = c.facts.member(parent, name) orelse return null;
    const record = c.project.at(field.file).model.declarations[@backingInt(field.index)];
    if (record.kind != .field) return null;
    const written = &c.project.at(field.file).file.tree;
    const declared = (c.project.at(field.file).model.containerField(written, record.node) orelse return null).ast.type_expr.unwrap() orelse return null;
    const kind = held(try c.facts.resolve(field.file, declared)) orelse return null;
    const field_of: Field = .{ .parent = parent, .name = name };
    const pointer = Facts.ungrouped(tree, args[1]);
    if (try interfaceField(c, node, pointer, field_of, kind)) return .{ field_of, kind, true };
    if (try listNode(c, pointer, field_of, kind)) return .{ field_of, kind, false };
    return null;
}

/// Whether the `@alignCast` call `node` is around a cleared `@fieldParentPtr`: its alignment
/// is the parent's, which that shape shows the pointer is.
pub fn clearedAlignment(c: *Context, node: Ast.Node.Index) Context.Error!Verdict {
    const tree = &c.project.at(c.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 1) return .open;
    const inner = Facts.ungrouped(tree, args[0]);
    if (!Facts.isBuiltin(tree, inner, "@fieldParentPtr")) return .open;
    return cleared(c, inner);
}

const Field = struct { parent: Facts.Container, name: []const u8 };

fn interfaceField(c: *Context, node: Ast.Node.Index, pointer: Ast.Node.Index, field: Field, kind: Facts.Container) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    // `p` is the converting function's own parameter, a pointer to F's type.
    const index = (try declaredIn(c, c.file, pointer)) orelse return false;
    const param = model.declarations[@backingInt(index)];
    if (param.kind != .parameter) return false;
    const function = enclosingFunction(tree, model, node) orelse return false;
    if (!parameterOf(tree, function, param.token)) return false;
    const interface = pointee(try c.facts.resolve(c.file, param.node)) orelse return false;
    if (!same(interface, kind)) return false;
    if (!try reachedOnlyInstalled(c, function, param.token, field, kind, 0)) return false;
    if (!try calledOnlyOnItself(c, kind)) return false;
    return addressedOnly(c, field, kind, true);
}

/// Whether every read in the package of a function an interface of type `kind` holds (a
/// function pointer field of it, or of the vtable it points at) calls it there and then on the
/// interface it was read from (`h.f(h)`, `x.F.f(&x.F)`, `w.vtable.drain(w, …)`, `i.f.?(io, i)`):
/// each parameter the function takes as a pointer to `kind` is given that interface. A function
/// read out and called on another pointer converts that pointer as though it were C.F's. A
/// read whose receiver does not resolve may be one, unless it names a type.
fn calledOnlyOnItself(c: *Context, kind: Facts.Container) Context.Error!bool {
    const source = c.project.at(kind.file);
    const tree = &source.file.tree;
    for (source.model.declarations) |decl| {
        if (decl.kind != .field or decl.scope != kind.scope) continue;
        const declared = (source.model.containerField(tree, decl.node) orelse continue).ast.type_expr.unwrap() orelse continue;
        const declared_type = try c.facts.resolve(kind.file, declared);
        if (functionPointer(declared_type)) |proto| {
            const given = (try interfaceParameters(c, proto, kind)) orelse return false;
            if (!try readsCalledOnSelf(c, decl.name, kind, false, given)) return false;
            continue;
        }
        // A vtable: each of its functions, read through this field.
        const table = pointee(declared_type) orelse continue;
        const inner = c.project.at(table.file);
        var any = false;
        for (inner.model.declarations) |entry| {
            if (entry.kind != .field or entry.scope != table.scope) continue;
            const entry_type = (inner.model.containerField(&inner.file.tree, entry.node) orelse continue).ast.type_expr.unwrap() orelse continue;
            const proto = functionPointer(try c.facts.resolve(table.file, entry_type)) orelse continue;
            const given = (try interfaceParameters(c, proto, kind)) orelse return false;
            if (!try readsCalledOnSelf(c, entry.name, table, true, given)) return false;
            any = true;
        }
        // The vtable itself read out (`w.vtable = s.interface.vtable`) carries its functions
        // to another interface: each read must take a function of it, or compare it. A pointer
        // to a struct with no function of its own (`reader: *Io.Reader`) is no vtable.
        if (any and !try tableReadInPlace(c, decl.name, kind)) return false;
    }
    // `@field(x, "vtable")` or `@field(x, "f")` of an interface names its functions too. One
    // written (`@field(out, name) = d`) installs, which the conversion it reaches judges.
    for (c.project.sources) |*each| {
        if (!try c.facts.program(each.id)) continue;
        const file_tree = &each.file.tree;
        for (file_tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (!Facts.isBuiltin(file_tree, node, "@field")) continue;
            if (try Facts.accesses.useOf(c.facts, each.id, node) == .written) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(file_tree, node, &buffer);
            if (args.len != 2) continue;
            const receiver = try c.facts.resolve(each.id, args[0]);
            if (receiver != .unknown and !isParent(receiver, kind)) continue;
            if (receiver == .unknown and (try generic(c, each.id, node) or try namesType(c, each.id, args[0]))) continue;
            for (source.model.declarations) |decl| {
                if (decl.kind != .field or decl.scope != kind.scope) continue;
                const declared = (source.model.containerField(tree, decl.node) orelse continue).ast.type_expr.unwrap() orelse continue;
                const declared_type = try c.facts.resolve(kind.file, declared);
                if (functionPointer(declared_type)) |_| {
                    // A member of it read, indexed or iterated: no function pointer.
                    if (try notFunction(c, each.id, node)) continue;
                } else if (declared_type != .pointer) continue;
                if (try namedBy(c, each.id, args[1], decl.name)) return false;
            }
        }
    }
    return true;
}

/// Whether each read of the vtable field `name` of an interface of type `kind` reads a
/// function of the table (`w.vtable.drain`), is written, or is compared.
fn tableReadInPlace(c: *Context, name: []const u8, kind: Facts.Container) Context.Error!bool {
    for (try c.facts.memberUses(name)) |use| {
        const tree = &c.project.at(use.file).file.tree;
        const receiver = tree.nodeData(use.node).node_and_token[0];
        const value = try c.facts.resolve(use.file, receiver);
        if (value == .unknown) {
            if (try namesType(c, use.file, receiver) or try generic(c, use.file, use.node)) continue;
            return false;
        }
        if (!isParent(value, kind)) continue;
        if (!try tableInPlace(c, use.file, use.node)) return false;
    }
    return true;
}

/// Whether the vtable read `use` reads a function of the table, is written, or is compared
/// (`Facts.accesses.useOf`).
fn tableInPlace(c: *Context, file: Project.FileId, use: Ast.Node.Index) Context.Error!bool {
    return switch (try Facts.accesses.useOf(c.facts, file, use)) {
        .member, .written, .compared => true,
        else => false,
    };
}

/// The positions of the parameters of the function type `proto` that are pointers to `kind`,
/// as bits; null where a type there does not resolve, or a position is past 63.
fn interfaceParameters(c: *Context, proto: Facts.Key, kind: Facts.Container) Context.Error!?u64 {
    const tree = &c.project.at(proto.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const full = tree.fullFnProto(&buffer, proto.node) orelse return null;
    var positions: u64 = 0;
    var it = full.iterate(tree);
    var position: u7 = 0;
    while (it.next()) |param| : (position += 1) {
        if (position == 64) return null;
        const declared = param.type_expr orelse return null;
        const value = try c.facts.resolve(proto.file, declared);
        if (value == .unknown) return null;
        if (pointee(value)) |to| if (same(to, kind)) {
            positions |= @as(u64, 1) << @intCast(position);
        };
    }
    return positions;
}

/// Whether each read of the function field `name` of a `holder` (directly, or of a vtable a
/// `through` field points at) is called at once, `.?` unwrapping it at most, with the interface
/// at each of the positions `given`.
fn readsCalledOnSelf(c: *Context, name: []const u8, holder: Facts.Container, through: bool, given: u64) Context.Error!bool {
    for (try c.facts.memberUses(name)) |use| {
        const tree = &c.project.at(use.file).file.tree;
        const receiver = tree.nodeData(use.node).node_and_token[0];
        const value = try c.facts.resolve(use.file, receiver);
        if (value == .unknown) {
            if (try namesType(c, use.file, receiver) or try notFunction(c, use.file, use.node) or try generic(c, use.file, use.node)) continue;
            return false;
        }
        if (!isParent(value, holder)) continue;
        if (!try calledOnSelf(c, use.file, use.node, through, given)) return false;
    }
    return true;
}

/// Whether the member read `use` is no function pointer: something reads a member of it,
/// indexes, slices or iterates it, which Zig allows no function pointer (`Facts.accesses.useOf`).
fn notFunction(c: *Context, file: Project.FileId, use: Ast.Node.Index) Context.Error!bool {
    return switch (try Facts.accesses.useOf(c.facts, file, use)) {
        .member, .element, .sliced, .looped => true,
        else => false,
    };
}

/// Whether the function read `use` (`x.f`, `x.vtable.f` where `through`) is called at once,
/// `.?` unwrapping it at most, with the interface it was read from at each position `given`;
/// or captured from its optional (`if (x.f) |f|`) or bound to a constant (`const f = x.f orelse
/// return e;`) and only called so, on an interface a parameter, a capture or a constant names,
/// which nothing changes in between. A read compared (`x.f != null`) calls nothing.
fn calledOnSelf(c: *Context, file: Project.FileId, use: Ast.Node.Index, through: bool, given: u64) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const receiver = tree.nodeData(use).node_and_token[0];
    // The interface: the receiver, or what the vtable was read from (`accesses.pathOf`).
    var interface = receiver;
    if (through) {
        const path = try Facts.accesses.pathOf(c.facts, file, receiver);
        if (path.steps.len < 2 or path.steps[0].kind != .field) return false;
        interface = path.steps[1].node;
    }
    var callee = use;
    switch (try Facts.accesses.useOf(c.facts, file, use)) {
        .compared => return true,
        .tested => |owner| {
            const branch = tree.fullIf(owner) orelse return false;
            if (!try fixed(c, file, interface)) return false;
            const payload = branch.payload_token orelse return false;
            if (tree.tokenTag(payload) == .asterisk) return false;
            for (model.declarations, 0..) |decl, d| {
                if (decl.kind != .capture or decl.node != owner or decl.token != payload) continue;
                return onlyCalledOnSelf(c, file, @fromBackingInt(@intCast(d)), interface, given);
            }
            return false;
        },
        .carried => |carry| if (carry.how == .unwrapped) {
            callee = carry.into;
        },
        else => {},
    }
    if (try boundConstant(c, file, callee)) |index| return try fixed(c, file, interface) and try onlyCalledOnSelf(c, file, index, interface, given);
    return switch (try Facts.accesses.useOf(c.facts, file, callee)) {
        .callee => |call| givenSelf(c, file, call, interface, given),
        else => false,
    };
}

/// Whether the call `call_node` is given `interface` at each position `given` (`Facts.calls`'
/// arguments), by value or by address: the place it names, or the one it points at
/// (`accesses.pointed`), is the interface's (`accesses.samePlace`).
fn givenSelf(c: *Context, file: Project.FileId, call_node: Ast.Node.Index, interface: Ast.Node.Index, given: u64) Context.Error!bool {
    const call = (try Facts.calls.at(c.facts, file, call_node)) orelse return false;
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => return false,
    };
    for (args, 0..) |argument, position| {
        if (position >= 64 or given & (@as(u64, 1) << @intCast(position)) == 0) continue;
        if (try Facts.accesses.samePlace(c.facts, file, argument, interface) == .yes) continue;
        const place = (try Facts.accesses.pointed(c.facts, file, argument)) orelse return false;
        if (try Facts.accesses.samePlace(c.facts, file, place, interface) != .yes) return false;
    }
    return args.len >= 64 or given >> @intCast(args.len) == 0;
}

/// Whether each reference to the capture or constant `index` calls it, `.?` unwrapping it at
/// most, given `interface` at each position `given`.
fn onlyCalledOnSelf(c: *Context, file: Project.FileId, index: Model.Declaration.Id, interface: Ast.Node.Index, given: u64) Context.Error!bool {
    for (try namings(c, file, .{ .file = file, .index = index }, false)) |reference| {
        var callee = reference;
        switch (try Facts.accesses.useOf(c.facts, file, reference)) {
            .carried => |carry| if (carry.how == .unwrapped) {
                callee = carry.into;
            },
            else => {},
        }
        switch (try Facts.accesses.useOf(c.facts, file, callee)) {
            .callee => |call| if (!try givenSelf(c, file, call, interface, given)) return false,
            else => return false,
        }
    }
    return true;
}

/// The constant the function read `node` (`x.f`, `x.f.?`) is bound to, alone or by an `orelse`
/// that leaves (`const f = x.f orelse return e;`): it holds what the read gave.
fn boundConstant(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Model.Declaration.Id {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var init = node;
    switch (try Facts.accesses.useOf(c.facts, file, node)) {
        .carried => |carry| if (carry.how == .payload) {
            if (tree.nodeTag(carry.into) != .@"orelse" or !leaves(tree, tree.nodeData(carry.into).node_and_node[1])) return null;
            init = carry.into;
        },
        else => {},
    }
    const holder = switch (try Facts.accesses.useOf(c.facts, file, init)) {
        .initializes => |holder| holder,
        else => return null,
    };
    const variable = tree.fullVarDecl(holder) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind == .variable and decl.node == holder) return @fromBackingInt(@intCast(d));
    }
    return null;
}

/// Whether evaluating `node` leaves the expression: it gives no value in its place.
fn leaves(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .@"return", .@"break", .@"continue", .unreachable_literal => true,
        else => false,
    };
}

/// The member read a capture or constant `node` names holds: an `if`'s (`if (x.f) |f|`), or
/// one `boundConstant` reads (`const f = x.f orelse return e;`).
fn capturedRead(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const index = (try declaredIn(c, file, node)) orelse return null;
    const decl = model.declarations[@backingInt(index)];
    switch (decl.kind) {
        .capture => {
            const branch = tree.fullIf(decl.node) orelse return null;
            if (branch.payload_token != decl.token or !try memberRead(c, file, branch.ast.cond_expr)) return null;
            return branch.ast.cond_expr;
        },
        .variable => {
            const variable = tree.fullVarDecl(decl.node) orelse return null;
            // The read its value carries (`accesses.carriedFrom`: through `orelse`, `.?`).
            var read = variable.ast.init_node.unwrap() orelse return null;
            for (0..3) |_| {
                if (try memberRead(c, file, read)) break;
                read = Facts.accesses.carriedFrom(tree, read) orelse return null;
            } else return null;
            if (try boundConstant(c, file, read) == index) return read;
            switch (try Facts.accesses.useOf(c.facts, file, read)) {
                .carried => |carry| if (carry.how == .unwrapped and try boundConstant(c, file, carry.into) == index) return read,
                else => {},
            }
            return null;
        },
        else => return null,
    }
}

/// Whether `node` is itself a member read (`x.f`, `@field(x, "f")`), by its place's path.
fn memberRead(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const path = try Facts.accesses.pathOf(c.facts, file, node);
    return path.steps.len > 1 and path.steps[0].kind == .field and path.steps[0].node == node;
}

/// Whether `node` names a parameter, a capture or a constant: what it holds cannot change.
fn fixed(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const index = (try declaredIn(c, file, node)) orelse return false;
    const decl = c.project.at(file).model.declarations[@backingInt(index)];
    return switch (decl.kind) {
        .parameter, .capture => true,
        .variable => if (tree.fullVarDecl(decl.node)) |variable| tree.tokenTag(variable.ast.mut_token) == .keyword_const else false,
        .function, .field => false,
    };
}

/// The declaration of `file` a name names (`Facts.definition`); null for anything else.
fn declaredIn(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Model.Declaration.Id {
    return switch (try c.facts.definition(file, node)) {
        .decl => |decl| if (decl.file == file) decl.index else null,
        .none, .unknown => null,
    };
}

/// The nodes of `file` that name `decl`: each reference Model resolves to it, and where `members`
/// (a container's member), each member read that may name it (`mayName`).
fn namings(c: *Context, file: Project.FileId, decl: Facts.Decl, members: bool) Context.Error![]const Ast.Node.Index {
    var out: std.ArrayList(Ast.Node.Index) = .empty;
    if (decl.file == file) for (c.project.at(file).model.references) |reference| {
        if (reference.unknown == null and reference.declaration == decl.index) try out.append(c.allocator, reference.node);
    };
    if (!members) return out.items;
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    for (try c.facts.memberUses(record.name)) |use| {
        if (use.file == file and try mayName(c, file, use.node, decl)) try out.append(c.allocator, use.node);
    }
    return out.items;
}

/// The function type a pointer to a function, or an optional one, points at.
fn functionPointer(value: Facts.Value) ?Facts.Key {
    return switch (value) {
        .optional => |inner| functionPointer(inner.*),
        .pointer => |to| if (to.child.* == .fn_type) to.child.fn_type else null,
        else => null,
    };
}

/// Whether the parameter at `token` of `function` is only ever given a pointer to C.F: the
/// function is not `pub`, and named only where C's own code installs it into C.F's value; or
/// each naming installs it so or calls it directly, that parameter given the same parameter of
/// a function that is so, a pointer to F's type (a helper the installed functions share, at
/// most four calls deep, which may be installed itself).
fn reachedOnlyInstalled(c: *Context, function: Ast.Node.Index, token: Ast.TokenIndex, field: Field, kind: Facts.Container, depth: u8) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, function) orelse return false;
    if (proto.visib_token != null) return false;
    const decl = functionDecl(model, function) orelse return false;
    if (try namedOnlyInstalling(c, decl, field, 4)) return true;
    if (depth >= 4) return false;
    var position: usize = 0;
    var it = proto.iterate(tree);
    while (it.next()) |param| : (position += 1) {
        if (param.name_token == token) break;
    } else return false;
    var called = false;
    for (try namings(c, c.file, .{ .file = c.file, .index = decl }, true)) |node| {
        // Read off a value, or off a holder that does not resolve: no install shown, nor a
        // helper's call (called on a value, it is handed that value first).
        if (try memberRead(c, c.file, node)) {
            const holder = (try Facts.accesses.pathOf(c.facts, c.file, node)).steps[0].holder orelse return false;
            if (holder != .container) return false;
        }
        // Installed here, into C.F's value as C's own code does: no call to follow.
        if (try installs(c, node, field, 4)) {
            called = true;
            continue;
        }
        const call_node = switch (try Facts.accesses.useOf(c.facts, c.file, node)) {
            .callee => |call| call,
            else => return false,
        };
        const call = (try Facts.calls.at(c.facts, c.file, call_node)) orelse return false;
        const args = switch (call.args) {
            .known => |known| known,
            .unknown => return false,
        };
        if (call.receiver != .none or position >= args.len) return false;
        const given_index = (try declaredIn(c, c.file, Facts.ungrouped(tree, args[position]))) orelse return false;
        const given = model.declarations[@backingInt(given_index)];
        if (given.kind != .parameter) return false;
        const caller = enclosingFunction(tree, model, node) orelse return false;
        if (!parameterOf(tree, caller, given.token)) return false;
        if (!same(pointee(try c.facts.resolve(c.file, given.node)) orelse return false, kind)) return false;
        if (!try reachedOnlyInstalled(c, caller, given.token, field, kind, depth + 1)) return false;
        called = true;
    }
    return called and !try namedByField(c, decl);
}

/// Whether the member access `node` of `file` may name `decl`: by its declaration where known;
/// where not, by the name it spells, as a member access names only a declaration of its name;
/// never a declaration that is not `pub` from another file, which Zig refuses, nor through a
/// module's path, which reaches only what the module exports by name.
fn mayName(c: *Context, file: Project.FileId, node: Ast.Node.Index, decl: Facts.Decl) Context.Error!bool {
    return switch (try c.facts.definition(file, node)) {
        .decl => |found| std.meta.eql(found, decl),
        .none => false,
        .unknown => |why| {
            // Read through a generic's parameter (`t.vtable.drain` with `t: anytype`): what it
            // names is each binding's, which the follow judges where the binding is made.
            if (why == .generic) return false;
            const tree = &c.project.at(file).file.tree;
            const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
            if (file != decl.file and !record.public and record.kind != .field) return false;
            if (c.facts.throughModule(file, tree.nodeData(node).node_and_token[0])) return false;
            const spelled = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(node).node_and_token[1]));
            return std.mem.eql(u8, spelled, record.name);
        },
    };
}

/// Whether every reference to `decl` in the checked file installs it into C.F's value, from
/// C's file; up to `through` constants that are not `pub` may stand between (a vtable, a
/// struct holding one), each named only so in turn.
fn namedOnlyInstalling(c: *Context, decl: Model.Declaration.Id, field: Field, through: u8) Context.Error!bool {
    const names = try namings(c, c.file, .{ .file = c.file, .index = decl }, true);
    for (names) |node| if (!try installs(c, node, field, through)) return false;
    return names.len != 0 and !try namedByField(c, decl);
}

/// Whether a `@field(C, "f")` in the checked file may name the function `decl`: it installs
/// nothing either path follows.
fn namedByField(c: *Context, decl: Model.Declaration.Id) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const record = model.declarations[@backingInt(decl)];
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (!Facts.isBuiltin(tree, node, "@field")) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        if (args.len != 2) continue;
        switch (try c.facts.resolve(c.file, args[0])) {
            .container, .instance => |container| if (container.file != c.file or container.scope != record.scope) continue,
            .unknown => {},
            else => continue,
        }
        if (try namedBy(c, c.file, args[1], record.name)) return true;
    }
    return false;
}

/// Whether the expression around `reference` puts it into C.F's value, in C's file, read by
/// each use it stands in (`Facts.accesses.useOf`): through literals, addresses and an `if`'s
/// branches up to `.F = …` of a literal that is a C, `x.F = …` of a C, or C.F's own default;
/// or, while `through` allows, into a container constant that is not `pub` whose every
/// reference does so. The function is not `pub`: only its own file names it.
fn installs(c: *Context, reference: Ast.Node.Index, field: Field, through: u8) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var at = reference;
    for (0..16) |_| {
        switch (try Facts.accesses.useOf(c.facts, c.file, at)) {
            .address => |taken| at = taken,
            .element_of => |element| at = element.literal,
            .carried => |carry| switch (carry.how) {
                .grouped => at = carry.into,
                // `if (c) f else null`: what is installed is it or the other branch's value.
                .prong => {
                    const branch = tree.fullIf(carry.into) orelse return false;
                    if (branch.payload_token != null or branch.error_token != null) return false;
                    at = carry.into;
                },
                else => return false,
            },
            // `x.F = f` of a C (`accesses.pathOf` of the store's target).
            .stored => |store| {
                const path = try Facts.accesses.pathOf(c.facts, c.file, store.target orelse return false);
                if (path.steps.len < 2 or path.steps[0].kind != .field) return false;
                if (!std.mem.eql(u8, path.steps[0].name orelse return false, field.name)) return false;
                if (!isParent(path.steps[0].holder orelse return false, field.parent)) return false;
                return field.parent.file == c.file;
            },
            .initializes => |holder| {
                // C.F's own default value, declared in C.
                if (model.containerField(tree, holder) != null) {
                    const own = c.facts.member(field.parent, field.name) orelse return false;
                    return own.file == c.file and model.declarations[@backingInt(own.index)].node == holder;
                }
                const variable = tree.fullVarDecl(holder) orelse return false;
                if (through == 0 or variable.visib_token != null or tree.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
                if (!containerLevel(tree, model, holder)) return false;
                const constant = for (model.declarations, 0..) |each, d| {
                    if (each.node == holder and each.kind == .variable) break @as(Model.Declaration.Id, @fromBackingInt(@intCast(d)));
                } else return false;
                return namedOnlyInstalling(c, constant, field, through - 1);
            },
            // `.F = …` of a literal C is the install; another field's value, the literal's.
            .field_of => |given| {
                if (std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(given.name)), field.name)) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const literal = tree.fullStructInit(&buffer, given.literal) orelse return false;
                    const container = if (literal.ast.type_expr.unwrap()) |t| held(try c.facts.resolve(c.file, t)) else try c.facts.resultContainer(c.file, given.literal);
                    if (container) |made| if (same(made, field.parent)) return field.parent.file == c.file;
                }
                at = given.literal;
            },
            else => return false,
        }
    }
    return false;
}

/// Whether every use of C.F in the package takes its address, reads a part of it, or calls a
/// method of it that takes it by pointer, and each pointer to it so made, followed to every
/// place it goes, stays one: none copies it. A use whose receiver does not resolve may be C's,
/// and shows nothing, unless it names a type. So do the interface parameters of every
/// function of C's file, which a vtable may hand C.F.
fn addressedOnly(c: *Context, field: Field, kind: Facts.Container, interface: bool) Context.Error!bool {
    var follow: Follow = .{ .c = c, .kind = kind, .contract = interface };
    for (try c.facts.memberUses(field.name)) |use| {
        const tree = &c.project.at(use.file).file.tree;
        const receiver = try c.facts.resolve(use.file, tree.nodeData(use.node).node_and_token[0]);
        if (receiver != .unknown and !isParent(receiver, field.parent)) continue;
        if (receiver == .unknown) {
            if (try namesType(c, use.file, tree.nodeData(use.node).node_and_token[0]) or try generic(c, use.file, use.node)) continue;
            return false;
        }
        switch (try Facts.accesses.useOf(c.facts, use.file, use.node)) {
            .address => |taken| if (!try follow.stays(use.file, taken)) return false,
            .written => {},
            .member => |access| if (!try follow.member(use.file, access)) return false,
            else => return false,
        }
    }
    // `@field(x, "F")` names it too; written whole, as `x.F = v`, it stays in place.
    for (c.project.sources) |*source| {
        if (!try c.facts.program(source.id)) continue;
        const tree = &source.file.tree;
        for (tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (!Facts.isBuiltin(tree, node, "@field")) continue;
            if (try Facts.accesses.useOf(c.facts, source.id, node) == .written) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 2) continue;
            // Of another type, it names none of C's fields.
            const receiver = try c.facts.resolve(source.id, args[0]);
            if (receiver != .unknown and !isParent(receiver, field.parent)) continue;
            if (receiver == .unknown and (try generic(c, source.id, node) or try namesType(c, source.id, args[0]))) continue;
            if (try namedBy(c, source.id, args[1], field.name)) return false;
        }
    }
    const model = &c.project.at(c.file).model;
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .parameter) continue;
        const to = pointee(try c.facts.resolve(c.file, decl.node)) orelse continue;
        if (!same(to, kind)) continue;
        if (!try follow.local(c.file, @fromBackingInt(@intCast(d)))) return false;
    }
    return true;
}

/// Whether a `@field` name may be `name` (`Facts.fieldName`, read by `Facts.mayName`): it spells
/// it, ranges over a list that names it or a struct that has it, or is computed as the program
/// compiles.
fn namedBy(c: *Context, file: Project.FileId, spelling: Ast.Node.Index, name: []const u8) Context.Error!bool {
    return c.facts.mayName(try c.facts.fieldName(file, spelling), name);
}

/// A pointer to an interface of type `kind` followed to every place it goes: through the
/// program's functions it is handed to, the locals and fields it is put in, the functions that
/// return it to their callers. It stays a pointer where it is compared, converted back by
/// `@fieldParentPtr`, has a part read or written, the whole written through it, or a method
/// called that takes it by pointer, followed into that function as into any other (std's too),
/// or a function of the interface called through it, given it where its type takes one.
/// A copy of what it points at (`p.*`, a by-value method), a place of another type it is put
/// in (a generic's parameter, `*anyopaque`, an array pointer, any builtin), a `pub` function
/// returning it, or a step past the budget, shows nothing.
const Follow = struct {
    c: *Context,
    kind: Facts.Container,
    /// An interface's: a `pub` function may return it, its callers held to `contract`.
    contract: bool = false,
    seen: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty,
    steps: usize = 0,

    /// Whether the pointer `node` in `file` stays one wherever its value goes, read by the use
    /// it stands in (`Facts.accesses.useOf`).
    fn stays(f: *Follow, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
        f.steps += 1;
        if (f.steps > 4096) return false;
        const c = f.c;
        const tree = &c.project.at(file).file.tree;
        switch (try Facts.accesses.useOf(c.facts, file, node)) {
            // Parentheses, `try`, `.?`, either side of `orelse` and `catch`, a branch's or a
            // prong's result, a `break`'s value: what holds it is the pointer.
            .carried => |carry| switch (carry.how) {
                .grouped, .tried, .unwrapped, .payload, .otherwise, .prong, .broken => return f.stays(file, carry.into),
                .compile_time, .@"nosuspend" => return false,
            },
            .compared => return true,
            // `p.*.x` reads or calls a part; `p.* = v` writes the whole in place.
            .dereferenced => |deref| return switch (try Facts.accesses.useOf(c.facts, file, deref)) {
                .written => true,
                .member => |access| f.member(file, access),
                else => false,
            },
            .member => |access| return f.member(file, access),
            // The pointer itself replaced, or dropped.
            .written, .discarded => return true,
            .stored => |store| return f.stored(file, store.target orelse return false),
            .returned => |returning| return f.returned(file, returning),
            .builtin_argument => |argument| {
                if (Facts.isBuiltin(tree, argument.call, "@fieldParentPtr")) return true;
                if (!Facts.isBuiltin(tree, argument.call, "@as")) return false;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, argument.call, &buffer);
                if (args.len != 2 or argument.position != 1 or !f.pointer(try c.facts.resolve(file, args[0]))) return false;
                return f.stays(file, argument.call);
            },
            .tested => |owner| {
                if (tree.fullIf(owner)) |branch| return f.tested(file, owner, branch.payload_token, branch.error_token);
                if (tree.fullWhile(owner)) |loop| return f.tested(file, owner, loop.payload_token, loop.error_token);
                return false;
            },
            .argument => |given| return f.passed(file, given.call, node),
            .initializes => |holder| {
                const variable = tree.fullVarDecl(holder) orelse return false;
                if (variable.ast.type_node.unwrap()) |declared| if (!f.pointer(try c.facts.resolve(file, declared))) return false;
                for (c.project.at(file).model.declarations, 0..) |each, d| {
                    if (each.node == holder and each.kind == .variable) return f.local(file, @fromBackingInt(@intCast(d)));
                }
                return false;
            },
            // `const a, const b = .{ x, p }`: the local it is destructured into.
            .element_of => |element| return (try f.destructured(file, element.literal, element.position)) orelse false,
            // `.{ .w = p }`: the field of the literal's type it is put in.
            .field_of => |given| {
                var fields: [2]Ast.Node.Index = undefined;
                const literal = tree.fullStructInit(&fields, given.literal) orelse return false;
                const container = (if (literal.ast.type_expr.unwrap()) |t| held(try c.facts.resolve(file, t)) else try c.facts.resultContainer(file, given.literal)) orelse return false;
                const decl = c.facts.member(container, try Model.identifier(c.allocator, tree.tokenSlice(given.name))) orelse return false;
                return f.field(decl);
            },
            else => return false,
        }
    }

    /// The element at `position` of the tuple literal `literal` destructured where it is made
    /// (`const a, const b = .{ x, p };`): followed as the local it goes to, as `const b = p;`
    /// is; into a place, not shown. Null where `literal` is no such literal.
    fn destructured(f: *Follow, file: Project.FileId, literal: Ast.Node.Index, position: usize) Context.Error!?bool {
        const tree = &f.c.project.at(file).file.tree;
        const model = &f.c.project.at(file).model;
        const whole = switch (try Facts.accesses.useOf(f.c.facts, file, literal)) {
            .destructured => |statement| statement,
            else => return null,
        };
        var buffer: [2]Ast.Node.Index = undefined;
        const elements = (tree.fullArrayInit(&buffer, literal) orelse return null).ast.elements;
        const full = tree.assignDestructure(whole);
        if (full.ast.variables.len != elements.len or position >= elements.len) return null;
        const target = full.ast.variables[position];
        const variable = tree.fullVarDecl(target) orelse return false;
        if (variable.ast.type_node.unwrap()) |declared| if (!f.pointer(try f.c.facts.resolve(file, declared))) return false;
        for (model.declarations, 0..) |each, d| {
            if (each.node == target and each.kind == .variable) return try f.local(file, @fromBackingInt(@intCast(d)));
        }
        return false;
    }

    /// The pointer handed to the call `call_node` as `node`: through a function pointer field
    /// (`o.vtable.see(o, n)`), what the interface's functions are handed, each installed one's
    /// parameter followed with its file's; to a function, its parameter there (`Facts.calls`'
    /// arguments), followed.
    fn passed(f: *Follow, file: Project.FileId, call_node: Ast.Node.Index, node: Ast.Node.Index) Context.Error!bool {
        const c = f.c;
        const tree = &c.project.at(file).file.tree;
        const call = (try Facts.calls.at(c.facts, file, call_node)) orelse return false;
        var callee = call.callee_expr;
        while (Facts.accesses.carriedFrom(tree, callee)) |inner| callee = inner;
        if (try capturedRead(c, file, callee)) |read| callee = read;
        // A member not known is read as the callee resolves, below.
        if (try memberRead(c, file, callee)) switch (try c.facts.definition(file, callee)) {
            .decl => |slot| {
                const record = c.project.at(slot.file).model.declarations[@backingInt(slot.index)];
                if (record.kind == .field) {
                    const slot_tree = &c.project.at(slot.file).file.tree;
                    const declared = (c.project.at(slot.file).model.containerField(slot_tree, record.node) orelse return false).ast.type_expr.unwrap() orelse return false;
                    const proto = functionPointer(try c.facts.resolve(slot.file, declared)) orelse return false;
                    const given = (try interfaceParameters(c, proto, f.kind)) orelse return false;
                    var buffer: [1]Ast.Node.Index = undefined;
                    const params = (tree.fullCall(&buffer, call_node) orelse return false).ast.params;
                    const position = std.mem.findScalar(Ast.Node.Index, params, node) orelse return false;
                    return position < 64 and given & (@as(u64, 1) << @intCast(position)) != 0;
                }
            },
            .none, .unknown => {},
        };
        const decl = switch (call.callee) {
            .function => |function| function,
            .choice, .any => return false,
        };
        const args = switch (call.args) {
            .known => |known| known,
            .unknown => return false,
        };
        return f.handed(decl, std.mem.findScalar(Ast.Node.Index, args, node) orelse return false);
    }

    /// An optional pointer an `if` or `while` tests (`while (it) |n|`): compared with null, and
    /// its capture holds the pointer, followed as a local. A capture of its address (`|*n|`) or
    /// an error union's shows nothing.
    fn tested(f: *Follow, file: Project.FileId, owner: Ast.Node.Index, payload: ?Ast.TokenIndex, error_token: ?Ast.TokenIndex) Context.Error!bool {
        if (error_token != null) return false;
        const token = payload orelse return true;
        const tree = &f.c.project.at(file).file.tree;
        if (tree.tokenTag(token) != .identifier) return false;
        for (f.c.project.at(file).model.declarations, 0..) |each, d| {
            if (each.kind == .capture and each.node == owner and each.token == token) return f.local(file, @fromBackingInt(@intCast(d)));
        }
        return false;
    }

    /// Whether a value is a pointer to the interface, or an optional one.
    fn pointer(f: *const Follow, value: Facts.Value) bool {
        const to = switch (value) {
            .pointer => |to| to.child.*,
            .optional => |inner| return f.pointer(inner.*),
            else => return false,
        };
        return if (held(to)) |container| same(container, f.kind) else false;
    }

    /// `p.name`: a part of the interface, read or written; or a method called with it, which
    /// takes it by pointer: std's, or the program's, followed into.
    fn member(f: *Follow, file: Project.FileId, access: Ast.Node.Index) Context.Error!bool {
        const c = f.c;
        // A member not known is not shown kept in place.
        const decl = switch (try c.facts.definition(file, access)) {
            .decl => |d| d,
            .none, .unknown => return false,
        };
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        if (record.kind == .field) return true;
        if (record.kind != .function) return false;
        if (try Facts.accesses.useOf(c.facts, file, access) != .callee) return false;
        return f.handed(decl, 0);
    }

    /// Whether the function `decl` given the pointer as its parameter `index` keeps it one:
    /// that parameter a pointer to the interface, and, in the program, followed.
    fn handed(f: *Follow, decl: Facts.Decl, index: usize) Context.Error!bool {
        const c = f.c;
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        if (record.kind != .function) return false;
        // std's own `Io.Writer` and `Io.Reader` methods keep the interface in place: Io's
        // contract, which every implementation's vtable is written to.
        if (f.contract and decl.file == f.kind.file and record.scope == f.kind.scope and try c.facts.standard(decl.file)) return true;
        const tree = &c.project.at(decl.file).file.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, record.node) orelse return false;
        var it = proto.iterate(tree);
        var position: usize = 0;
        const param = while (it.next()) |each| : (position += 1) {
            if (position == index) break each;
        } else return false;
        if (!f.pointer(try c.facts.resolve(decl.file, param.type_expr orelse return false))) return false;
        // Its body, std's as the program's, followed; one with none (`extern`) shows nothing.
        const body = c.project.at(decl.file).model.parentOf(record.node) orelse return false;
        if (tree.nodeTag(body) != .fn_decl) return false;
        const name = param.name_token orelse return false;
        for (c.project.at(decl.file).model.declarations, 0..) |each, d| {
            if (each.kind == .parameter and each.token == name) return f.local(decl.file, @fromBackingInt(@intCast(d)));
        }
        return false;
    }

    /// Every reference to a local or parameter holding the pointer.
    fn local(f: *Follow, file: Project.FileId, index: Model.Declaration.Id) Context.Error!bool {
        const c = f.c;
        if ((try f.seen.getOrPut(c.allocator, .{ .file = file, .index = index })).found_existing) return true;
        for (try namings(c, file, .{ .file = file, .index = index }, false)) |node| {
            if (!try f.stays(file, node)) return false;
        }
        return true;
    }

    /// `x = p` where `x` is a local or a field of the interface's pointer type.
    fn stored(f: *Follow, file: Project.FileId, target: Ast.Node.Index) Context.Error!bool {
        const c = f.c;
        const decl = switch (try c.facts.definition(file, target)) {
            .decl => |d| d,
            .none, .unknown => return false,
        };
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        return switch (record.kind) {
            .variable => {
                if (!f.pointer(try c.facts.resolve(file, target))) return false;
                return f.local(decl.file, decl.index);
            },
            .field => f.field(decl),
            else => false,
        };
    }

    /// A field of the interface's pointer type the pointer is put in: every read of it, in
    /// the program, followed.
    fn field(f: *Follow, decl: Facts.Decl) Context.Error!bool {
        const c = f.c;
        if ((try f.seen.getOrPut(c.allocator, decl)).found_existing) return true;
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        if (record.kind != .field) return false;
        const declared = (c.project.at(decl.file).model.containerField(&c.project.at(decl.file).file.tree, record.node) orelse return false).ast.type_expr.unwrap() orelse return false;
        if (!f.pointer(try c.facts.resolve(decl.file, declared))) return false;
        // A field others outside the program can read may carry it anywhere.
        if (record.public) return false;
        for (try c.facts.memberUses(record.name)) |use| {
            // A use whose member is not known is this field unless its holder shows it is not.
            const found = switch (try c.facts.definition(use.file, use.node)) {
                .decl => |d| d,
                .none, .unknown => {
                    const tree = &c.project.at(use.file).file.tree;
                    const receiver = tree.nodeData(use.node).node_and_token[0];
                    if (try namesType(c, use.file, receiver)) continue;
                    // A part of a value of another type, whichever of its types it is, is not this field.
                    if (otherThan(try c.facts.resolve(use.file, receiver), .{ .file = decl.file, .scope = record.scope })) continue;
                    return false;
                },
            };
            if (!std.meta.eql(found, decl)) continue;
            if (!try f.stays(use.file, use.node)) return false;
        }
        return true;
    }

    /// `return p`: every call of the function, which is not `pub`, followed.
    fn returned(f: *Follow, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
        const c = f.c;
        const tree = &c.project.at(file).file.tree;
        const model = &c.project.at(file).model;
        const function = enclosingFunction(tree, model, node) orelse return false;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, function) orelse return false;
        if (proto.visib_token != null) return f.contract;
        if (!f.pointer(try c.facts.resolve(file, proto.ast.return_type.unwrap() orelse return false))) {
            const result = try c.facts.resolve(file, proto.ast.return_type.unwrap() orelse return false);
            if (result != .error_union or !f.pointer(result.error_union.*)) return false;
        }
        const index = functionDecl(model, function) orelse return false;
        if ((try f.seen.getOrPut(c.allocator, .{ .file = file, .index = index })).found_existing) return true;
        for (try namings(c, file, .{ .file = file, .index = index }, true)) |each| {
            switch (try Facts.accesses.useOf(c.facts, file, each)) {
                .callee => |call| if (!try f.stays(file, call)) return false,
                else => return false,
            }
        }
        return true;
    }
};

/// What C.F's conversions come to once every generic a C is handed to has been read.
pub const Verdict = enum { shown, open, undecided };

/// Whether a C handed to a generic (an `anytype` parameter, or one whose type the program
/// does not fix) keeps C.F in a C there, read in the callee's body wherever it is: the
/// program's, std's or a dependency's. Memoized per field: every conversion of C.F shares it.
fn generics(c: *Context, field: Field, kind: Facts.Container, interface: bool) Context.Error!Verdict {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const decl = c.facts.member(field.parent, field.name) orelse return .open;
    const known = try c.facts.memo(Generics);
    if (known.verdicts.get(decl)) |verdict| return verdict;
    var carry: Carry = .{ .c = c, .field = field, .follow = .{ .c = c, .kind = kind, .contract = interface } };
    const verdict = try carry.program();
    try known.verdicts.put(c.allocator, decl, verdict);
    return verdict;
}

const Generics = struct { verdicts: std.AutoHashMapUnmanaged(Facts.Decl, Verdict) = .empty };

/// A C (`.whole`: a C, a pointer to one) or something that may hold one (`.held`: a tuple or
/// struct with one among its values, an array of them), followed from where the program hands
/// it to a function into that function's body and on. A copy of a whole C is a C, with its F
/// in it. C.F read out by value, by its name or by a `@field` name that may be it, or a carrier
/// given to a builtin other than a type's, is a copy of the interface: open. A body that is
/// not there to read (an `extern`, a function pointer, `@call`), a place the follow does not
/// know, or a step past the budget, is undecided.
const Carry = struct {
    c: *Context,
    field: Field,
    follow: Follow,
    seen: std.AutoHashMapUnmanaged(struct { Facts.Decl, Shape }, void) = .empty,
    steps: usize = 0,

    const Shape = enum { whole, held };
    const budget = 8192;

    fn worst(a: Verdict, b: Verdict) Verdict {
        if (a == .open or b == .open) return .open;
        if (a == .undecided or b == .undecided) return .undecided;
        return .shown;
    }

    /// Every call in the program given a carrier.
    fn program(k: *Carry) Context.Error!Verdict {
        const c = k.c;
        var verdict: Verdict = .shown;
        for (c.project.sources) |*source| {
            if (!try c.facts.program(source.id)) continue;
            const tree = &source.file.tree;
            for (tree.nodes.items(.tag), 0..) |_, i| {
                const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                var buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buffer, node) orelse continue;
                for (call.ast.params) |argument| {
                    const shape = (try k.carries(source.id, argument, 0)) orelse continue;
                    verdict = worst(verdict, try k.handedOn(source.id, node, argument, shape, true));
                    if (verdict == .open) return .open;
                }
            }
        }
        return verdict;
    }

    /// Whether the expression `node` is a carrier, and how.
    fn carries(k: *Carry, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!?Shape {
        if (depth == 32) return .held;
        const c = k.c;
        const tree = &c.project.at(file).file.tree;
        const at = Facts.ungrouped(tree, node);
        // `&x`: what it points at (`accesses.pointed`).
        if (try Facts.accesses.pointed(c.facts, file, at)) |place| if (place != at) return k.carries(file, place, depth + 1);
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullStructInit(&buffer, at)) |literal| {
            for (literal.ast.fields) |value| if (try k.carries(file, value, depth + 1) != null) return .held;
            return null;
        }
        if (tree.fullArrayInit(&buffer, at)) |literal| {
            for (literal.ast.elements) |value| if (try k.carries(file, value, depth + 1) != null) return .held;
            return null;
        }
        const value = try c.facts.resolve(file, at);
        if (value == .literal) return if (try k.carries(value.literal.file, value.literal.node, depth + 1) != null) .held else null;
        return k.holds(value, depth);
    }

    /// Whether a value is a C, a pointer to one, or holds them.
    fn holds(k: *Carry, value: Facts.Value, depth: u8) Context.Error!?Shape {
        if (depth == 32) return .held;
        return switch (value) {
            .instance => |container| if (same(container, k.field.parent)) .whole else null,
            .pointer => |inner| try k.holds(inner.child.*, depth + 1),
            .optional, .error_union => |inner| try k.holds(inner.*, depth + 1),
            .array => |element| if (try k.holds(element.*, depth + 1) != null) .held else null,
            else => null,
        };
    }

    /// The call `call_node` given a carrier as `argument`: the callee's parameter it is
    /// (`Facts.calls`' arguments, a bound receiver first) followed through its body. A parameter
    /// of the program's own that is a C or a pointer to one is read by the program-wide checks
    /// already.
    fn handedOn(k: *Carry, file: Project.FileId, call_node: Ast.Node.Index, argument: Ast.Node.Index, shape: Shape, from_program: bool) Context.Error!Verdict {
        const c = k.c;
        const tree = &c.project.at(file).file.tree;
        const call = (try Facts.calls.at(c.facts, file, call_node)) orelse return .undecided;
        const decl = switch (call.callee) {
            .function => |function| function,
            .choice, .any => return .undecided,
        };
        const args = switch (call.args) {
            .known => |known| known,
            .unknown => return .undecided,
        };
        const index = std.mem.findScalar(Ast.Node.Index, args, argument) orelse return .undecided;
        // std's `Io.async` and `Io.concurrent`, a `Group`'s and a `Select`'s, call `function`
        // with `args`, the tuple they copy whole: a carrier in a tuple written there is handed
        // to `function` where it stands in it.
        if (index > 0 and try spawnArguments(c, decl, index)) {
            var buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullArrayInit(&buffer, Facts.ungrouped(tree, argument))) |tuple| {
                return k.spawned(file, args[index - 1], tuple.ast.elements, from_program);
            }
        }
        return k.parameter(decl, index, shape, from_program);
    }

    /// A function `function` names, given the elements of the tuple `args` in order: each
    /// carrier among them handed to its parameter there.
    fn spawned(k: *Carry, file: Project.FileId, function: Ast.Node.Index, args: []const Ast.Node.Index, from_program: bool) Context.Error!Verdict {
        const c = k.c;
        const decl = switch (try c.facts.resolve(file, function)) {
            .function => |each| each,
            else => return .undecided,
        };
        var verdict: Verdict = .shown;
        for (args, 0..) |argument, at| {
            const shape = (try k.carries(file, argument, 0)) orelse continue;
            verdict = worst(verdict, try k.parameter(decl, at, shape, from_program));
            if (verdict == .open) return .open;
        }
        return verdict;
    }

    /// The function `decl` given a carrier as its parameter `index`: that parameter followed
    /// through its body.
    fn parameter(k: *Carry, decl: Facts.Decl, index: usize, shape: Shape, from_program: bool) Context.Error!Verdict {
        const c = k.c;
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        if (record.kind != .function) return .undecided;
        // std's `mem.Allocator` frees, resizes and copies items whole, by its contract: a C
        // moved whole is a C, its F in it.
        if (try allocatorMethod(c, decl)) return .shown;
        const callee = &c.project.at(decl.file).file.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = callee.fullFnProto(&buffer, record.node) orelse return .undecided;
        var it = proto.iterate(callee);
        var at: usize = 0;
        const param = while (it.next()) |each| : (at += 1) {
            if (at == index) break each;
        } else return .undecided;
        if (param.type_expr) |declared| {
            const value = try c.facts.resolve(decl.file, declared);
            // Typed, in the program: what the program does with a C is read there.
            if (from_program and try c.facts.program(decl.file) and try k.holds(value, 0) == .whole) return .shown;
            if (pointee(value)) |to| if (opaqueType(c, to)) return .open;
        }
        const body = c.project.at(decl.file).model.parentOf(record.node) orelse return .undecided;
        if (callee.nodeTag(body) != .fn_decl) return .undecided;
        const name = param.name_token orelse return .shown;
        for (c.project.at(decl.file).model.declarations, 0..) |each, d| {
            if (each.kind == .parameter and each.token == name) return k.local(decl.file, @fromBackingInt(@intCast(d)), shape);
        }
        return .undecided;
    }

    /// Every reference to a parameter or local holding a carrier.
    fn local(k: *Carry, file: Project.FileId, index: Model.Declaration.Id, shape: Shape) Context.Error!Verdict {
        const c = k.c;
        if ((try k.seen.getOrPut(c.allocator, .{ .{ .file = file, .index = index }, shape })).found_existing) return .shown;
        var verdict: Verdict = .shown;
        for (try namings(c, file, .{ .file = file, .index = index }, false)) |node| {
            verdict = worst(verdict, try k.goes(file, node, shape));
            if (verdict == .open) return .open;
        }
        return verdict;
    }

    /// Where the carrier `node` goes, by the use it stands in (`Facts.accesses.useOf`).
    fn goes(k: *Carry, file: Project.FileId, node: Ast.Node.Index, shape: Shape) Context.Error!Verdict {
        k.steps += 1;
        if (k.steps > budget) return .undecided;
        const c = k.c;
        const tree = &c.project.at(file).file.tree;
        const model = &c.project.at(file).model;
        switch (try Facts.accesses.useOf(c.facts, file, node)) {
            // Through parentheses, `try`, `.?`, `orelse` and `catch`, a branch's, a prong's or a
            // `break`'s value, `.*` and `&`: what holds it carries it.
            .carried => |carry| return switch (carry.how) {
                .compile_time, .@"nosuspend" => .undecided,
                else => k.goes(file, carry.into, shape),
            },
            .dereferenced, .address => |outer| return k.goes(file, outer, shape),
            // Compared, an operator's operand, written over, a type: no copy of C.F.
            .compared, .operand, .written, .updated, .discarded, .typed => return .shown,
            .member => |access| return k.member(file, access, shape),
            .stored => |store| return k.into(file, store.target orelse return .undecided, shape),
            .initializes => |holder| {
                _ = tree.fullVarDecl(holder) orelse return .undecided;
                for (model.declarations, 0..) |each, d| {
                    if (each.node == holder and each.kind == .variable) return k.local(file, @fromBackingInt(@intCast(d)), shape);
                }
                return .undecided;
            },
            .tested => |owner| {
                if (tree.fullIf(owner)) |branch| return k.captured(file, owner, branch.payload_token, shape);
                if (tree.fullWhile(owner)) |loop| return k.captured(file, owner, loop.payload_token, shape);
                return .undecided;
            },
            // Its elements, each captured: any of them may be a C.
            .looped => |input| {
                var verdict: Verdict = .shown;
                for (model.declarations, 0..) |each, d| {
                    if (each.kind != .capture or each.node != input.loop) continue;
                    verdict = worst(verdict, try k.local(file, @fromBackingInt(@intCast(d)), .held));
                }
                return verdict;
            },
            .argument => |given| return k.handedOn(file, given.call, node, shape, false),
            .element_of => |element| return k.goes(file, element.literal, .held),
            .field_of => |given| return k.goes(file, given.literal, .held),
            .builtin_argument => |given| {
                for ([_][]const u8{ "@TypeOf", "@sizeOf", "@alignOf", "@bitSizeOf", "@hasField", "@hasDecl", "@intFromPtr" }) |typed| {
                    if (Facts.isBuiltin(tree, given.call, typed)) return .shown;
                }
                if (Facts.isBuiltin(tree, given.call, "@as")) return k.goes(file, given.call, shape);
                if (Facts.isBuiltin(tree, given.call, "@field")) {
                    var args_buffer: [2]Ast.Node.Index = undefined;
                    const args = Facts.builtinArgs(tree, given.call, &args_buffer);
                    if (args.len != 2 or given.position != 0) return .shown;
                    return k.part(file, given.call, args[1], shape);
                }
                if (Facts.isBuiltin(tree, given.call, "@call")) return .undecided;
                return .open;
            },
            else => return .undecided,
        }
    }

    /// `if (x) |v|`, `while (x) |v|`: the capture holds the carrier.
    fn captured(k: *Carry, file: Project.FileId, owner: Ast.Node.Index, payload: ?Ast.TokenIndex, shape: Shape) Context.Error!Verdict {
        const token = payload orelse return .shown;
        const tree = &k.c.project.at(file).file.tree;
        const name = if (tree.tokenTag(token) == .asterisk) token + 1 else token;
        for (k.c.project.at(file).model.declarations, 0..) |each, d| {
            if (each.kind == .capture and each.node == owner and each.token == name) return k.local(file, @fromBackingInt(@intCast(d)), shape);
        }
        return .undecided;
    }

    /// `x = carrier`: into a local, followed; into a carrier's own place (`a.* = b.*`), a C
    /// where a C was; elsewhere undecided. The place by its path (`accesses.pathOf`).
    fn into(k: *Carry, file: Project.FileId, target: Ast.Node.Index, shape: Shape) Context.Error!Verdict {
        const c = k.c;
        const path = try Facts.accesses.pathOf(c.facts, file, target);
        const root = switch (path.root) {
            .decl => |decl| decl,
            .none, .unknown => return .undecided,
        };
        if (path.steps.len == 1) return k.local(root.file, root.index, shape);
        if (k.seen.contains(.{ root, .whole }) or k.seen.contains(.{ root, .held })) return .shown;
        return .undecided;
    }

    /// `carrier.name`: C.F where it may be it, and what else the part may hold.
    fn member(k: *Carry, file: Project.FileId, access: Ast.Node.Index, shape: Shape) Context.Error!Verdict {
        const tree = &k.c.project.at(file).file.tree;
        const name = try Model.identifier(k.c.allocator, tree.tokenSlice(tree.nodeData(access).node_and_token[1]));
        return k.named(file, access, name, shape);
    }

    /// `@field(carrier, name)`: the one name it spells (`Facts.fieldName`); a name computed as
    /// the program compiles may be any part.
    fn part(k: *Carry, file: Project.FileId, access: Ast.Node.Index, spelling: Ast.Node.Index, shape: Shape) Context.Error!Verdict {
        return switch (try k.c.facts.fieldName(file, spelling)) {
            .name => |name| k.named(file, access, name, shape),
            .each_of, .names, .computed => k.anyPart(file, access),
        };
    }

    fn anyPart(k: *Carry, file: Project.FileId, access: Ast.Node.Index) Context.Error!Verdict {
        return worst(try k.interface(file, access), try k.goes(file, access, .held));
    }

    fn named(k: *Carry, file: Project.FileId, access: Ast.Node.Index, name: []const u8, shape: Shape) Context.Error!Verdict {
        const c = k.c;
        const is_field = std.mem.eql(u8, name, k.field.name);
        switch (shape) {
            .held => {
                const rest = try k.goes(file, access, .held);
                return if (is_field) worst(try k.interface(file, access), rest) else rest;
            },
            .whole => {
                if (is_field) return k.interface(file, access);
                const decl = c.facts.member(k.field.parent, name) orelse return .shown;
                const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
                // A method of C, or a declaration: the program's, typed, read there.
                if (record.kind != .field) return .shown;
                const declared = (c.project.at(decl.file).model.containerField(&c.project.at(decl.file).file.tree, record.node) orelse return .undecided).ast.type_expr.unwrap() orelse return .undecided;
                const value = try c.facts.resolve(decl.file, declared);
                if (value == .unknown) return k.goes(file, access, .held);
                return if (try k.holds(value, 0)) |inner| k.goes(file, access, inner) else .shown;
            },
        }
    }

    /// C.F itself, reached in a body: its address followed, a part of it read or a method of
    /// it called, written whole; anything else copies it (`Facts.accesses.useOf`).
    fn interface(k: *Carry, file: Project.FileId, access: Ast.Node.Index) Context.Error!Verdict {
        const c = k.c;
        switch (try Facts.accesses.useOf(c.facts, file, access)) {
            .address => |taken| return if (try k.follow.stays(file, taken)) .shown else .open,
            .member => |outer| {
                // Its part or method by name on F's type: in a generic, `x` does not resolve.
                const path = try Facts.accesses.pathOf(c.facts, file, outer);
                const name = path.steps[0].name orelse return .open;
                const decl = c.facts.member(k.follow.kind, name) orelse return .open;
                const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
                if (record.kind == .field) return .shown;
                if (record.kind != .function) return .open;
                if (try Facts.accesses.useOf(c.facts, file, outer) != .callee) return .open;
                return if (try k.follow.handed(decl, 0)) .shown else .open;
            },
            .written => return .shown,
            else => return .open,
        }
    }
};

/// Whether `decl` is a function of std's `mem.Allocator`.
fn allocatorMethod(c: *Context, decl: Facts.Decl) Context.Error!bool {
    if (!try c.facts.standard(decl.file)) return false;
    const scope = c.project.at(decl.file).model.declarations[@backingInt(decl.index)].scope;
    // One not known to be (std's declarations past the budget) is read in its body.
    const found_all = switch (try Governed.declarations(c, "std", "mem.Allocator")) {
        .decls => |each| each,
        .none, .unknown => return false,
    };
    for (found_all) |found| {
        const allocator = held(try c.facts.declaration(found)) orelse continue;
        if (allocator.file == decl.file and allocator.scope == scope) return true;
    }
    return false;
}

/// Whether the parameter `index` of std's function `decl` is the `args` tuple an Io spawn
/// (`Io.async`, `Io.concurrent`, a `Group`'s, a `Select`'s) calls the `function` before it
/// with: `function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))`, in std's Io.
fn spawnArguments(c: *Context, decl: Facts.Decl, index: usize) Context.Error!bool {
    if (index == 0 or !try c.facts.standard(decl.file)) return false;
    // One not known to be (std's declarations past the budget) has its parameter followed in
    // its body.
    const io_all = switch (try Governed.declarations(c, "std", "Io")) {
        .decls => |each| each,
        .none, .unknown => return false,
    };
    const io = for (io_all) |found| {
        if (held(try c.facts.declaration(found))) |container| break container;
    } else return false;
    if (io.file != decl.file) return false;
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return false;
    var it = proto.iterate(tree);
    var at: usize = 0;
    var function: ?Ast.TokenIndex = null;
    while (it.next()) |param| : (at += 1) {
        const name = tree.tokenSlice(param.name_token orelse return false);
        if (at + 1 == index) {
            if (param.anytype_ellipsis3 == null) return false;
            function = param.name_token;
        }
        if (at != index) continue;
        if (!std.mem.eql(u8, name, "args")) return false;
        // `std.meta.ArgsTuple(@TypeOf(function))`.
        var call_buffer: [1]Ast.Node.Index = undefined;
        const tuple = tree.fullCall(&call_buffer, param.type_expr orelse return false) orelse return false;
        const made_by = switch (try c.facts.definition(decl.file, tuple.ast.fn_expr)) {
            .decl => |made_by| made_by,
            .none, .unknown => return false,
        };
        if (try Governed.isStd(c, made_by, "meta.ArgsTuple") != .yes) return false;
        if (tuple.ast.params.len != 1 or !Facts.isBuiltin(tree, tuple.ast.params[0], "@TypeOf")) return false;
        var args_buffer: [2]Ast.Node.Index = undefined;
        const typed = Facts.builtinArgs(tree, tuple.ast.params[0], &args_buffer);
        if (typed.len != 1) return false;
        // The `function` parameter itself, by the declaration `@TypeOf`'s operand names.
        const named = switch (try c.facts.definition(decl.file, typed[0])) {
            .decl => |named| named,
            .none, .unknown => return false,
        };
        const record = c.project.at(named.file).model.declarations[@backingInt(named.index)];
        return named.file == decl.file and record.kind == .parameter and record.token == (function orelse return false);
    }
    return false;
}

/// Whether a container is `anyopaque`, which a pointer to anything coerces to.
fn opaqueType(c: *Context, container: Facts.Container) bool {
    const tree = &c.project.at(container.file).file.tree;
    const node = c.project.at(container.file).model.scopes[@backingInt(container.scope)].node;
    return tree.nodeTag(node) == .container_decl and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "opaque");
}

/// The interface contract. An interface is a type whose functions take a pointer to it and
/// recover the struct around it by `@fieldParentPtr`: std's `Io.Writer` and `Io.Reader`, and
/// every type a loaded file converts its own parameter from so. It works only where it was
/// installed, so in every file glint checks it is used in place: never copied by value out of
/// a place that may be its parent's field (`w.*`, `s.interface` or an element passed, returned,
/// put in a local, a field or a literal; a variable's own copy is not one), its functions and vtable
/// never read out or called on another interface, and a pointer to it handed only where the
/// function given it is read and keeps it in place. A pointer to one may then go anywhere,
/// a `pub` function's result included: what could break it is flagged where it is done. A
/// consumer glint does not check is not covered (std's own rule: an interface is not copied).
pub fn contract(c: *Context, rule: Rule) Context.Error!void {
    const kinds = (try interfaces(c)) orelse
        return c.undecided(rule, 0, .budget_exhausted, "std's Io.Writer and Io.Reader are not read within the fact budget: no interface in this file is checked");
    if (kinds.len == 0) return;
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        // What reads a value that may be an interface (`Facts.accesses.formOf`): a name, a
        // member, an element, `.*`, `.?`, a call or a builtin's result.
        const form = Facts.accesses.formOf(tag);
        switch (form) {
            .member, .deref, .array_access, .unwrap_optional, .call, .builtin => {},
            .leaf => if (try c.facts.definition(c.file, node) == .none) continue,
            else => continue,
        }
        const token = tree.nodeMainToken(node);
        if (c.inTest(token)) continue;
        if (Facts.isBuiltin(tree, node, "@field")) if (try namesFunction(c, kinds, node)) {
            try c.at(rule, token, "@field naming an interface's function or vtable: a function its implementation installed, read out, recovers its parent by @fieldParentPtr from whatever it is then given");
            continue;
        };
        const value = try c.facts.resolve(c.file, node);
        // A call's result is a value of its own; a copy that made it was flagged where made.
        if (form != .call) if (held(value)) |container| if (value == .instance and interfaceOf(kinds, container) != null and try copied(c, c.file, node) and !try ownStorage(c, node)) {
            try c.at(rule, token, "a copy of an interface: its functions recover the struct around it by @fieldParentPtr, which a copy is not in; keep it where it was installed and pass its address");
            continue;
        };
        if (form == .member and !try readInPlace(c, kinds, node)) {
            try c.at(rule, token, "an interface's function or vtable read out, or called on another interface: it recovers its parent by @fieldParentPtr from the interface it is given");
            continue;
        }
        const target = if (value == .instance) value.instance else pointee(value) orelse continue;
        const kind = interfaceOf(kinds, target) orelse continue;
        switch (try handedInPlace(c, kind, node)) {
            .shown => {},
            .open => try c.at(rule, token, "an interface handed to a function that may copy it or read its functions out: its functions recover the struct around it by @fieldParentPtr"),
            .undecided => try c.undecided(rule, tree.tokenStart(token), .unresolved, "an interface handed to a function not known here: whether it keeps the interface in place is not decided"),
        }
    }
}

/// Whether `node` names a variable, a parameter or a capture: storage of its own, never the
/// field of a struct its functions recover, so a copy of it breaks nothing. The copy that put
/// an installed interface there was flagged where it was made.
fn ownStorage(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    // Storage not known to be its own may be a field's.
    const decl = switch (try c.facts.definition(c.file, node)) {
        .decl => |d| d,
        .none, .unknown => return false,
    };
    return switch (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind) {
        .variable, .parameter, .capture => true,
        .function, .field => false,
    };
}

const Interfaces = struct { kinds: ?[]const Facts.Container = null, handed: std.AutoHashMapUnmanaged(struct { Facts.Container, Facts.Decl, usize }, bool) = .empty };

/// std's `Io.Writer` and `Io.Reader`, and each type a loaded file outside std converts its own
/// parameter from by `@fieldParentPtr`; null where std's are not known (its declarations read
/// past the budget), which is never kept.
fn interfaces(c: *Context) Context.Error!?[]const Facts.Container {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const known = try c.facts.memo(Interfaces);
    if (known.kinds) |kinds| return kinds;
    var kinds: std.ArrayList(Facts.Container) = .empty;
    for ([_][]const u8{ "Io.Writer", "Io.Reader" }) |path| {
        const found_all = switch (try Governed.declarations(c, "std", path)) {
            .decls => |each| each,
            .none => continue,
            .unknown => return null,
        };
        for (found_all) |found| {
            if (held(try c.facts.declaration(found))) |kind| if (interfaceOf(kinds.items, kind) == null) try kinds.append(c.allocator, kind);
        }
    }
    for (c.project.sources) |*source| {
        if (source.file.status != .parsed or try c.facts.standard(source.id)) continue;
        const tree = &source.file.tree;
        for (tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (!Facts.isBuiltin(tree, node, "@fieldParentPtr")) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 2) continue;
            const pointer = Facts.ungrouped(tree, args[1]);
            const index = (try declaredIn(c, source.id, pointer)) orelse continue;
            const param = source.model.declarations[@backingInt(index)];
            if (param.kind != .parameter) continue;
            const kind = pointee(try c.facts.resolve(source.id, param.node)) orelse continue;
            if (interfaceOf(kinds.items, kind) == null) try kinds.append(c.allocator, kind);
        }
    }
    known.kinds = try kinds.toOwnedSlice(c.allocator);
    return known.kinds.?;
}

fn interfaceOf(kinds: []const Facts.Container, container: Facts.Container) ?Facts.Container {
    for (kinds) |kind| if (same(kind, container)) return kind;
    return null;
}

/// Whether the value `node` is copied where it is: put in a local, a place, a literal, given
/// by value, returned, captured by value. A part read, an address taken, a type asked, a write
/// to it, are not.
fn copied(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    var at = node;
    while (true) switch (try Facts.accesses.useOf(c.facts, file, at)) {
        .carried => |carry| switch (carry.how) {
            // Its value goes on as what holds it: parentheses, `try`, `orelse` and `catch`, a
            // branch's or a prong's result.
            .grouped, .tried, .payload, .otherwise, .prong => at = carry.into,
            .unwrapped => return false,
            .broken, .compile_time, .@"nosuspend" => return true,
        },
        // A part read, an address taken, compared, written over, dropped, a type: no copy.
        .member, .address, .dereferenced, .compared, .written, .discarded, .typed => return false,
        .tested => |owner| {
            const payload = if (tree.fullIf(owner)) |branch| branch.payload_token else if (tree.fullWhile(owner)) |loop| loop.payload_token else return true;
            return payload != null and tree.tokenTag(payload.?) != .asterisk;
        },
        .builtin_argument => |given| {
            for ([_][]const u8{ "@TypeOf", "@sizeOf", "@alignOf", "@bitSizeOf", "@hasField", "@hasDecl", "@field" }) |typed| {
                if (Facts.isBuiltin(tree, given.call, typed)) return false;
            }
            if (!Facts.isBuiltin(tree, given.call, "@as")) return true;
            at = given.call;
        },
        else => return true,
    };
}

/// Whether the member read `access` of an interface (or of its vtable) is in place: a function
/// called then and there on the interface it was read from, a vtable read for a function of it,
/// compared or written. Another member, or another type's, is not one of these.
fn readInPlace(c: *Context, kinds: []const Facts.Container, access: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    // A function written in is an installation, which the conversion it reaches judges.
    if (try Facts.accesses.useOf(c.facts, c.file, access) == .written) return true;
    const receiver = try c.facts.resolve(c.file, tree.nodeData(access).node_and_token[0]);
    const name = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(access).node_and_token[1]));
    for (kinds) |kind| {
        for (try functions(c, kind)) |slot| {
            if (!std.mem.eql(u8, slot.name, name) or !isParent(receiver, slot.holder)) continue;
            if (slot.table) return tableInPlace(c, c.file, access);
            const given = slot.given orelse return false;
            if (!try calledOnSelf(c, c.file, access, slot.through, given)) return false;
        }
    }
    return true;
}

/// A function an interface holds: a function pointer field of it (`holder` the interface), a
/// vtable field (`table`), or a function of the vtable (`through`, `holder` the table); with
/// the positions of its parameters that take the interface, null where they do not resolve.
const Slot = struct { holder: Facts.Container, name: []const u8, table: bool = false, through: bool = false, given: ?u64 = null };
const Slots = struct { found: std.AutoHashMapUnmanaged(Facts.Container, []const Slot) = .empty };

fn functions(c: *Context, kind: Facts.Container) Context.Error![]const Slot {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const known = try c.facts.memo(Slots);
    if (known.found.get(kind)) |slots| return slots;
    var slots: std.ArrayList(Slot) = .empty;
    const source = c.project.at(kind.file);
    const tree = &source.file.tree;
    for (source.model.declarations) |decl| {
        if (decl.kind != .field or decl.scope != kind.scope) continue;
        const declared = (source.model.containerField(tree, decl.node) orelse continue).ast.type_expr.unwrap() orelse continue;
        const declared_type = try c.facts.resolve(kind.file, declared);
        if (functionPointer(declared_type)) |proto| {
            try slots.append(c.allocator, .{ .holder = kind, .name = decl.name, .given = try interfaceParameters(c, proto, kind) });
            continue;
        }
        const table = pointee(declared_type) orelse continue;
        const inner = c.project.at(table.file);
        var any = false;
        for (inner.model.declarations) |entry| {
            if (entry.kind != .field or entry.scope != table.scope) continue;
            const entry_type = (inner.model.containerField(&inner.file.tree, entry.node) orelse continue).ast.type_expr.unwrap() orelse continue;
            const proto = functionPointer(try c.facts.resolve(table.file, entry_type)) orelse continue;
            try slots.append(c.allocator, .{ .holder = table, .name = entry.name, .through = true, .given = try interfaceParameters(c, proto, kind) });
            any = true;
        }
        if (any) try slots.append(c.allocator, .{ .holder = kind, .name = decl.name, .table = true });
    }
    try known.found.put(c.allocator, kind, slots.items);
    return slots.items;
}

/// Whether `@field(x, name)` names a function or the vtable of an interface `x` is, or may be.
fn namesFunction(c: *Context, kinds: []const Facts.Container, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 2) return false;
    const receiver = try c.facts.resolve(c.file, args[0]);
    for (kinds) |kind| for (try functions(c, kind)) |slot| {
        if (!isParent(receiver, slot.holder)) continue;
        if (try namedBy(c, c.file, args[1], slot.name)) return true;
    };
    return false;
}

/// Whether `node` names the payload an `if` or a `while` captures by value from a field it reads
/// (`if (h.f) |f|`): what that field holds.
fn capturedField(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const index = (try declaredIn(c, c.file, node)) orelse return false;
    const record = model.declarations[@backingInt(index)];
    if (record.kind != .capture) return false;
    const payload = if (tree.fullIf(record.node)) |branch| branch.payload_token else if (tree.fullWhile(record.node)) |loop| loop.payload_token else return false;
    if (payload != record.token) return false;
    const source = Facts.ungrouped(tree, c.facts.captureSource(c.file, record) orelse return false);
    if (!try memberRead(c, c.file, source)) return false;
    return switch (try c.facts.definition(c.file, source)) {
        .decl => |member| c.project.at(member.file).model.declarations[@backingInt(member.index)].kind == .field,
        .none, .unknown => false,
    };
}

/// Whether an interface (or a pointer to one) `node` is handed only where it stays in place:
/// to a function of a file this run checks whose parameter is a pointer to it, whose copies
/// the contract reports there; to any other function (std's, a dependency's, the program's
/// in a file not checked) whose body is followed and keeps it so. A part read, a function of it
/// called on itself, is no handing. Read by the use it stands in (`Facts.accesses.useOf`) and
/// the call's arguments (`Facts.calls`).
fn handedInPlace(c: *Context, kind: Facts.Container, value: Ast.Node.Index) Context.Error!Verdict {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const tree = &c.project.at(c.file).file.tree;
    // `&w.*`, `(w)`: the same interface handed.
    var node = value;
    var use = try Facts.accesses.useOf(c.facts, c.file, node);
    while (true) {
        node = switch (use) {
            .carried => |carry| if (carry.how == .grouped) carry.into else break,
            .address => |taken| taken,
            else => break,
        };
        use = try Facts.accesses.useOf(c.facts, c.file, node);
    }
    var decl: Facts.Decl = undefined;
    var index: usize = 0;
    switch (use) {
        .member => |access| {
            const found = switch (try c.facts.definition(c.file, access)) {
                .decl => |d| d,
                // No member so named: nothing is handed.
                .none => return .shown,
                .unknown => return .undecided,
            };
            if (c.project.at(found.file).model.declarations[@backingInt(found.index)].kind != .function) return .shown;
            if (try Facts.accesses.useOf(c.facts, c.file, access) != .callee) return .shown;
            decl = found;
        },
        .argument => |given| {
            const call = (try Facts.calls.at(c.facts, c.file, given.call)) orelse return .shown;
            // Through a function field (`o.vtable.see(o, n)`, `h.f.?(h)`): no receiver is passed,
            // and the read is judged where it is, by `readInPlace`, whatever the field may hold.
            var read = call.callee_expr;
            while (Facts.accesses.carriedFrom(tree, read)) |inner| read = inner;
            // Or through what a capture reads out of one (`if (h.f) |f| f(h)`), the same call.
            if (try capturedField(c, read)) return .shown;
            // A member not known is read as the callee resolves, below.
            if (try memberRead(c, c.file, read)) switch (try c.facts.definition(c.file, read)) {
                .decl => |member| if (c.project.at(member.file).model.declarations[@backingInt(member.index)].kind == .field) return .shown,
                .none, .unknown => {},
            };
            // A callee that is no one function (a pointer, a choice, one not known) is not followed.
            decl = switch (call.callee) {
                .function => |function| function,
                .choice, .any => return .undecided,
            };
            const args = switch (call.args) {
                .known => |known| known,
                .unknown => return .undecided,
            };
            index = std.mem.findScalar(Ast.Node.Index, args, node) orelse return .shown;
        },
        else => return .shown,
    }
    var follow: Follow = .{ .c = c, .kind = kind, .contract = true };
    // A function of a checked file taking a pointer to it: its body is checked as this is.
    if (c.project.at(decl.file).input.selected) {
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        const callee = &c.project.at(decl.file).file.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        if (callee.fullFnProto(&buffer, record.node)) |proto| {
            var it = proto.iterate(callee);
            var at: usize = 0;
            while (it.next()) |param| : (at += 1) if (at == index) {
                // A pointer to it, or a copy of its own (whose function reads are checked there).
                if (param.type_expr) |declared| {
                    const declared_value = try c.facts.resolve(decl.file, declared);
                    if (follow.pointer(declared_value)) return .shown;
                    if (declared_value == .container and same(declared_value.container, kind)) return .shown;
                }
                break;
            };
        }
    }
    const known = try c.facts.memo(Interfaces);
    const key = .{ kind, decl, index };
    const kept = known.handed.get(key) orelse kept: {
        const kept = try follow.handed(decl, index);
        try known.handed.put(c.allocator, key, kept);
        break :kept kept;
    };
    return if (kept) .shown else .open;
}

const List = enum { doubly, singly };

fn listNode(c: *Context, pointer: Ast.Node.Index, field: Field, kind: Facts.Container) Context.Error!bool {
    const list: List = for ([_]List{ .doubly, .singly }) |each| switch (try isList(c, kind, "Node", each)) {
        .yes => break each,
        .no => {},
        .unknown => return false,
    } else return false;
    const source = (try nodeSource(c, c.file, pointer, field, list, null, 0)) orelse return false;
    if (source == .same) return false;
    if (!try insertsOnlyParents(c, field, list, source)) return false;
    if (!try listsInPlace(c, list)) return false;
    return addressedOnly(c, field, kind, false);
}

const Match = enum { yes, no, unknown };

/// Whether `container` is std's list `list`, or its `member` (`Node`) where one is named: not
/// known where std's declarations are not read (the budget). Each caller takes `unknown` the
/// way that shows nothing.
fn isList(c: *Context, container: Facts.Container, member: []const u8, list: List) Context.Error!Match {
    const name = switch (list) {
        .doubly => "DoublyLinkedList",
        .singly => "SinglyLinkedList",
    };
    const path = if (member.len == 0) name else try c.allocator.print("{s}.{s}", .{ name, member });
    const found_all = switch (try Governed.declarations(c, "std", path)) {
        .decls => |each| each,
        .none => return .no,
        .unknown => return .unknown,
    };
    for (found_all) |found| {
        if (held(try c.facts.declaration(found))) |known| if (same(known, container)) return .yes;
    }
    return .no;
}

/// The list a node comes out of: the declaration holding it (a field or a variable); `.any`
/// for a node that is `&c.F` of a C itself; `.same` for the local being traced, read again
/// (`while (it) |n| : (it = n.next)`), which adds nothing.
const Source = union(enum) { any, same, list: Facts.Decl };

/// Where the node `node` comes from, if it is `&c.F` of a C or out of one list: its `first` or
/// `last`, `popFirst()` or `popLast()`, or a node's `next` or `prev` out of the same list, also
/// through a local whose every value is one, or a capture of one. std's members by their
/// declarations (`stdMember`).
fn nodeSource(c: *Context, file: Project.FileId, node: Ast.Node.Index, field: Field, list: List, tracing: ?Model.Declaration.Id, depth: usize) Context.Error!?Source {
    if (depth == 8) return null;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const at = Facts.ungrouped(tree, node);
    // `&c.F` of a C: the place it points at (`accesses.pointed`).
    if (try Facts.accesses.pointed(c.facts, file, at)) |place| if (place != at) {
        const path = try Facts.accesses.pathOf(c.facts, file, place);
        if (path.steps.len < 2 or path.steps[0].kind != .field) return null;
        if (!std.mem.eql(u8, path.steps[0].name orelse return null, field.name)) return null;
        if (!isParent(path.steps[0].holder orelse return null, field.parent)) return null;
        return .any;
    };
    switch (tree.nodeTag(at)) {
        // `x orelse return null`: the other side leaves, adding nothing; a value there is a
        // node too.
        .@"orelse", .@"catch" => {
            const value, const otherwise = tree.nodeData(at).node_and_node;
            const found = (try nodeSource(c, file, value, field, list, tracing, depth + 1)) orelse return null;
            if (leaves(tree, otherwise)) return found;
            return joinSource(found, (try nodeSource(c, file, otherwise, field, list, tracing, depth + 1)) orelse return null);
        },
        else => {},
    }
    // `x.?`, `try x`: what it carries.
    if (Facts.accesses.carriedFrom(tree, at)) |inner| return nodeSource(c, file, inner, field, list, tracing, depth + 1);
    // `l.popFirst()`, `l.popLast()`: a node out of the list it is called on.
    if (try Facts.calls.at(c.facts, file, at)) |call| {
        const callee = switch (call.callee) {
            .function => |decl| decl,
            .choice, .any => return null,
        };
        if (!try stdMember(c, callee, list, &.{ "popFirst", "popLast" }, false)) return null;
        return switch (call.receiver) {
            .bound => |receiver| listOf(c, file, receiver, list),
            .none, .unknown => null,
        };
    }
    // `l.first`, `l.last`: out of the list; `n.next`, `n.prev`: out of the one `n` is.
    if (try memberRead(c, file, at)) {
        const receiver = (try Facts.accesses.pathOf(c.facts, file, at)).steps[1].node;
        const member = switch (try c.facts.definition(file, at)) {
            .decl => |decl| decl,
            .none, .unknown => return null,
        };
        if (try stdMember(c, member, list, &.{ "first", "last" }, false)) return listOf(c, file, receiver, list);
        if (try stdMember(c, member, list, &.{ "next", "prev" }, true)) {
            const from = (try nodeSource(c, file, receiver, field, list, tracing, depth + 1)) orelse return null;
            // A C's own node is in no list this shows.
            return if (from == .any) null else from;
        }
        return null;
    }
    const index = (try declaredIn(c, file, at)) orelse return null;
    if (tracing == index) return .same;
    const decl = model.declarations[@backingInt(index)];
    if (decl.kind == .capture) {
        // `while (it) |n|` or `if (x) |n|`: what the condition gives.
        const condition = if (tree.fullWhile(decl.node)) |loop| loop.ast.cond_expr else if (tree.fullIf(decl.node)) |branch| branch.ast.cond_expr else return null;
        return nodeSource(c, file, condition, field, list, tracing, depth + 1);
    }
    if (decl.kind != .variable) return null;
    // Its first value, and every later one put in it whole (`Facts.accesses.writes`), out of
    // the same list; its address writes it wherever that goes.
    var found: ?Source = null;
    const in_file = [_]Project.FileId{file};
    var writes = Facts.accesses.writes(c.facts, .{ .declaration = .{ .file = file, .index = index } }, &in_file);
    while (try writes.next()) |write| switch (write.kind) {
        .read => {},
        .init, .set => {
            if (write.part) return null;
            const value = write.value orelse return null;
            const next = (try nodeSource(c, file, value, field, list, index, depth + 1)) orelse return null;
            found = joinSource(found, next) orelse return null;
        },
        .update, .covered, .address, .open => return null,
    };
    return found;
}

/// Whether `decl` is one of std's `list` members `names` (of its `Node` where `node`).
fn stdMember(c: *Context, decl: Facts.Decl, list: List, names: []const []const u8, node: bool) Context.Error!bool {
    const type_name = switch (list) {
        .doubly => "DoublyLinkedList",
        .singly => "SinglyLinkedList",
    };
    for (names) |name| {
        const path = try c.allocator.print("{s}{s}.{s}", .{ type_name, if (node) ".Node" else "", name });
        if (try Governed.isStd(c, decl, path) == .yes) return true;
    }
    return false;
}

fn joinSource(a: ?Source, b: Source) ?Source {
    const first = a orelse return b;
    if (first == .same) return b;
    if (b == .same) return first;
    if (first == .any) return b;
    if (b == .any) return first;
    return if (std.meta.eql(first.list, b.list)) first else null;
}

/// The declaration a list expression names: a field or a variable, never a parameter or
/// anything that does not resolve, where `list` is that list's type.
fn listOf(c: *Context, file: Project.FileId, receiver: Ast.Node.Index, list: List) Context.Error!?Source {
    const value = try c.facts.resolve(file, receiver);
    const container = held(value) orelse switch (value) {
        .pointer => |to| held(to.child.*) orelse return null,
        else => return null,
    };
    if (try isList(c, container, "", list) != .yes) return null;
    const decl = switch (try c.facts.definition(file, receiver)) {
        .decl => |d| d,
        .none, .unknown => return null,
    };
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .field and record.kind != .variable) return null;
    return .{ .list = decl };
}

/// Whether every way the package puts a node into a list that may be `source`'s puts `&c.F`
/// of a C: std's insertions (`append`, `prepend`, `insertAfter`, `insertBefore`, a node's
/// `insertAfter`), each reached by its declaration and called there on a list or a node, and
/// a store to a list's or node's links, which may carry a node out of that same list and no
/// other (`p.free.first = p.busy.first` mixes them). A list moved into another (`concatByMoving`) is shown
/// nothing of. An insertion named any other way (`@call`, `const add = L.append`, a type's
/// member read out), a link's address, or a `@field` that may name either, shows nothing.
fn insertsOnlyParents(c: *Context, field: Field, list: List, source: Source) Context.Error!bool {
    const Insert = struct { name: []const u8, moves: bool = false };
    const inserts: []const Insert = switch (list) {
        .doubly => &.{ .{ .name = "append" }, .{ .name = "prepend" }, .{ .name = "insertAfter" }, .{ .name = "insertBefore" }, .{ .name = "concatByMoving", .moves = true } },
        .singly => &.{ .{ .name = "prepend" }, .{ .name = "insertAfter" } },
    };
    const links = [_][]const u8{ "first", "last", "next", "prev" };
    for (inserts) |insert| for (try c.facts.memberUses(insert.name)) |use| {
        const tree = &c.project.at(use.file).file.tree;
        // Which it is, by its receiver's type: std's list or its node; a receiver that does
        // not resolve may be either.
        const receiver = tree.nodeData(use.node).node_and_token[0];
        const of = (try receiverKind(c, use.file, receiver, list)) orelse continue;
        // Named on the type (`std.DoublyLinkedList.append`): a function value that may insert
        // anything, wherever it is called.
        switch (try c.facts.resolve(use.file, receiver)) {
            .container => return false,
            else => {},
        }
        const call_node = switch (try Facts.accesses.useOf(c.facts, use.file, use.node)) {
            .callee => |call| call,
            else => return false,
        };
        if (insert.moves) {
            if (of != .node and try mayBe(c, use.file, receiver, source)) return false;
            continue;
        }
        if (of == .list and !try mayBe(c, use.file, receiver, source)) continue;
        // The node put in: the last argument.
        const call = (try Facts.calls.at(c.facts, use.file, call_node)) orelse return false;
        const args = switch (call.args) {
            .known => |known| known,
            .unknown => return false,
        };
        if (args.len < 2) return false;
        const inserted = (try nodeSource(c, use.file, args[args.len - 1], field, list, null, 0)) orelse return false;
        if (inserted != .any) return false;
    };
    for (links) |link| for (try c.facts.memberUses(link)) |use| {
        const tree = &c.project.at(use.file).file.tree;
        if ((try receiverKind(c, use.file, tree.nodeData(use.node).node_and_token[0], list)) == null) continue;
        const store = switch (try Facts.accesses.useOf(c.facts, use.file, use.node)) {
            // A link's address writes it wherever that goes.
            .address => return false,
            .written => |store| store,
            else => continue,
        };
        const value = Facts.ungrouped(tree, store.value orelse return false);
        if (Facts.isNull(tree, value)) continue;
        const stored = (try nodeSource(c, use.file, value, field, list, null, 0)) orelse return false;
        // A C's own node anywhere; a node out of a list only into that same list's links.
        if (stored == .any) continue;
        if (stored != .list) return false;
        const receiver = tree.nodeData(use.node).node_and_token[0];
        const into: Source = (try listOf(c, use.file, receiver, list)) orelse (try nodeSource(c, use.file, receiver, field, list, null, 0)) orelse return false;
        if (into != .list or !std.meta.eql(into.list, stored.list)) return false;
    };
    // `@field(l, "first")`, `@field(L, "append")`: named so, a link or an insertion.
    for (c.project.sources) |*each| {
        if (!try c.facts.program(each.id)) continue;
        const tree = &each.file.tree;
        for (tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (!Facts.isBuiltin(tree, node, "@field")) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 2) continue;
            if ((try receiverKind(c, each.id, args[0], list)) == null) continue;
            for (links ++ [_][]const u8{ "append", "prepend", "insertAfter", "insertBefore", "concatByMoving" }) |name| {
                if (try namedBy(c, each.id, args[1], name)) return false;
            }
        }
    }
    return true;
}

/// Whether no list or node of `list`'s kind is made or copied whole in the package except
/// empty: a literal of either gives each link `null`, a whole one assigned is such a literal,
/// and none is read out by value (`p.free = b.items`, `var l = p.free`, `p.*` of either), which
/// carries its links to another place that may insert anything after them. A literal or a
/// place whose type does not resolve may be one.
fn listsInPlace(c: *Context, list: List) Context.Error!bool {
    for (c.project.sources) |*each| {
        if (!try c.facts.program(each.id)) continue;
        const file = each.id;
        const tree = &each.file.tree;
        const model = &each.model;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            var buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullStructInit(&buffer, node)) |literal| {
                var linked = false;
                for (literal.ast.fields) |value| {
                    const first = tree.firstToken(value);
                    if (first < 2 or tree.tokenTag(first - 2) != .identifier) continue;
                    const name = try Model.identifier(c.allocator, tree.tokenSlice(first - 2));
                    const is_link = for ([_][]const u8{ "first", "last", "next", "prev" }) |link| {
                        if (std.mem.eql(u8, name, link)) break true;
                    } else false;
                    const plain = Facts.ungrouped(tree, value);
                    if (is_link and !Facts.isNull(tree, plain)) linked = true;
                }
                if (!linked) continue;
                const container = if (literal.ast.type_expr.unwrap()) |t| held(try c.facts.resolve(file, t)) else try c.facts.resultContainer(file, node);
                const made = container orelse return false;
                if (try isList(c, made, "", list) != .no or try isList(c, made, "Node", list) != .no) return false;
                continue;
            }
            // A name, a member, `.*`, an element, a payload: what may be a list in a place.
            switch (Facts.accesses.formOf(tag)) {
                .leaf, .member, .deref, .array_access, .unwrap_optional => {},
                else => continue,
            }
            const value = try c.facts.resolve(file, node);
            const container = switch (value) {
                .instance => |container| container,
                else => continue,
            };
            if (try isList(c, container, "", list) == .no and try isList(c, container, "Node", list) == .no) continue;
            // In place: its address, a member of it, a whole write to it.
            const parent = model.parentOf(node) orelse return false;
            switch (try Facts.accesses.useOf(c.facts, file, node)) {
                .address, .member => continue,
                .written => |store| {
                    var literal_buffer: [2]Ast.Node.Index = undefined;
                    if (tree.fullStructInit(&literal_buffer, Facts.ungrouped(tree, store.value orelse return false)) == null) return false;
                },
                else => {
                    // Its declaration names it, as its type, not as a value.
                    if (try Facts.accesses.memberRead(c.facts, file, node) == null) switch (try c.facts.definition(file, node)) {
                        .decl => |named| if (named.file == file and model.declarations[@backingInt(named.index)].node == parent) continue,
                        .none, .unknown => {},
                    };
                    return false;
                },
            }
        }
        // A parameter of either by value is a copy of what its caller gives.
        for (model.declarations) |decl| {
            if (decl.kind != .parameter) continue;
            const declared = decl.node;
            const container = switch (try c.facts.resolve(file, declared)) {
                .container, .instance => |container| container,
                else => continue,
            };
            if (try isList(c, container, "", list) != .no or try isList(c, container, "Node", list) != .no) return false;
        }
        // A local of either initialised from a place, not a literal.
        for (model.declarations) |decl| {
            if (decl.kind != .variable) continue;
            const variable = tree.fullVarDecl(decl.node) orelse continue;
            const init = Facts.ungrouped(tree, variable.ast.init_node.unwrap() orelse continue);
            var literal_buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullStructInit(&literal_buffer, init) != null) continue;
            const container = switch (try c.facts.resolve(file, init)) {
                .instance => |container| container,
                else => continue,
            };
            if (try isList(c, container, "", list) != .no or try isList(c, container, "Node", list) != .no) return false;
        }
    }
    return true;
}

const Receiver = enum { list, node, unknown };

/// What a receiver is, of `list`'s kind: the list, its node, or (not resolving) either; null
/// for anything else.
fn receiverKind(c: *Context, file: Project.FileId, receiver: Ast.Node.Index, list: List) Context.Error!?Receiver {
    const value = try c.facts.resolve(file, receiver);
    if (value == .unknown) return .unknown;
    const container = held(value) orelse switch (value) {
        .pointer => |to| held(to.child.*),
        else => null,
    } orelse return null;
    const whole = try isList(c, container, "", list);
    if (whole == .yes) return .list;
    const node = try isList(c, container, "Node", list);
    if (node == .yes) return .node;
    if (whole == .unknown or node == .unknown) return .unknown;
    return null;
}

/// Whether the list expression `receiver` may be `source`'s list: it is, or it names no other
/// field or variable.
fn mayBe(c: *Context, file: Project.FileId, receiver: Ast.Node.Index, source: Source) Context.Error!bool {
    const decl = switch (try c.facts.definition(file, receiver)) {
        .decl => |d| d,
        .none, .unknown => return true,
    };
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .field and record.kind != .variable) return true;
    // A local holding a list's address names that list, which this does not follow.
    if (record.kind == .variable and c.project.at(decl.file).model.scopes[@backingInt(record.scope)].kind != .container) return true;
    return switch (source) {
        .any, .same => true,
        .list => |held_list| std.meta.eql(held_list, decl),
    };
}

/// The struct a `@fieldParentPtr` at `node` in `file` converts to, where its result location
/// names one.
pub fn converts(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Facts.Container {
    return pointee(try resultType(c, file, node));
}

/// The type the result location of `node` names: a declaration's type, `@as`, a function's
/// result, an assignment's target; through `@alignCast`, `try` and parentheses.
fn resultType(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!Facts.Value {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = node;
    for (0..8) |_| {
        const parent = model.parentOf(at) orelse return .{ .unknown = .unresolved };
        switch (try Facts.accesses.useOf(c.facts, file, at)) {
            .carried => |onward| switch (onward.how) {
                .grouped, .tried => {
                    at = onward.into;
                    continue;
                },
                else => {},
            },
            .returned => |ret| {
                const function = enclosingFunction(tree, model, ret) orelse return .{ .unknown = .unresolved };
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, function) orelse return .{ .unknown = .unresolved };
                return c.facts.resolve(file, proto.ast.return_type.unwrap() orelse return .{ .unknown = .unresolved });
            },
            .stored => |store| {
                if (store.node != parent) return .{ .unknown = .unresolved };
                return c.facts.resolve(file, store.target orelse return .{ .unknown = .unresolved });
            },
            else => {},
        }
        if (Facts.isBuiltin(tree, parent, "@alignCast")) {
            at = parent;
            continue;
        }
        if (Facts.isBuiltin(tree, parent, "@as")) {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, parent, &buffer);
            if (args.len != 2 or args[1] != at) return .{ .unknown = .unresolved };
            return c.facts.resolve(file, args[0]);
        }
        if (tree.fullVarDecl(parent)) |variable| {
            if (variable.ast.init_node.unwrap() != at) return .{ .unknown = .unresolved };
            return c.facts.resolve(file, variable.ast.type_node.unwrap() orelse return .{ .unknown = .unresolved });
        }
        return .{ .unknown = .unresolved };
    }
    return .{ .unknown = .unresolved };
}

/// The container a single-item pointer type points at.
fn pointee(value: Facts.Value) ?Facts.Container {
    return switch (value) {
        .pointer => |to| held(to.child.*),
        .optional, .error_union => |inner| pointee(inner.*),
        else => null,
    };
}

fn held(value: Facts.Value) ?Facts.Container {
    return switch (value) {
        .container, .instance => |container| container,
        else => null,
    };
}

fn same(a: Facts.Container, b: Facts.Container) bool {
    return a.file == b.file and a.scope == b.scope;
}

/// Whether a value is a C, or a pointer to one.
/// Whether `value` is known to be of a type other than `holder`: a container, an instance or a
/// pointer to one that is not it, or alternatives each of which is.
fn otherThan(value: Facts.Value, holder: Facts.Container) bool {
    return switch (value) {
        .container, .instance => |container| !same(container, holder),
        .pointer => |to| otherThan(to.child.*, holder),
        .optional => |to| otherThan(to.*, holder),
        .alternatives => |each| for (each) |one| {
            if (!otherThan(one, holder)) break false;
        } else each.len != 0,
        else => false,
    };
}

fn isParent(value: Facts.Value, parent: Facts.Container) bool {
    return switch (value) {
        .container, .instance => |container| same(container, parent),
        .pointer => |to| isParent(to.child.*, parent),
        else => false,
    };
}

fn containerLevel(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    const parent = model.parentOf(node) orelse return true;
    if (tree.nodeTag(parent) == .root) return true;
    var buffer: [2]Ast.Node.Index = undefined;
    return tree.fullContainerDecl(&buffer, parent) != null;
}

fn enclosingFunction(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Ast.Node.Index {
    var up = model.parentOf(node);
    while (up) |parent| : (up = model.parentOf(parent)) if (tree.nodeTag(parent) == .fn_decl) return tree.nodeData(parent).node_and_node[0];
    return null;
}

/// Whether `node` is in a generic function's body: one taking `anytype`, a type or any
/// `comptime` parameter, or within a function returning a type. A member read there on what does not resolve is of what its
/// parameters hold, which a caller hands it: an interface by pointer, followed into the body
/// (`Follow.handed`), or a struct holding one (`Carry`). The program-wide scans leave it to them.
fn generic(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var up = model.parentOf(node);
    while (up) |parent| : (up = model.parentOf(parent)) {
        if (tree.nodeTag(parent) != .fn_decl) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(parent).node_and_node[0]) orelse continue;
        if (proto.ast.return_type.unwrap()) |returned| if (try c.facts.typeIsType(file, returned)) return true;
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            if (param.anytype_ellipsis3 != null) return true;
            if (param.comptime_noalias) |token| if (tree.tokenTag(token) == .keyword_comptime) return true;
            if (param.type_expr) |declared| if (try c.facts.typeIsType(file, declared)) return true;
        }
    }
    return false;
}

/// Whether the parameter named at `token` is one of the prototype `function`'s own.
fn parameterOf(tree: *const Ast, function: Ast.Node.Index, token: Ast.TokenIndex) bool {
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, function) orelse return false;
    var it = proto.iterate(tree);
    while (it.next()) |param| if (param.name_token == token) return true;
    return false;
}

fn functionDecl(model: *const Model, proto: Ast.Node.Index) ?Model.Declaration.Id {
    for (model.declarations, 0..) |each, d| {
        if (each.kind == .function and each.node == proto) return @fromBackingInt(@intCast(d));
    }
    return null;
}

/// Whether `node` names a type, not a value: a constant an `@import` of a Zig file makes, a
/// builtin that makes a type (`@Enum`, `@Struct`, …), or a call of a function declared to
/// return `type`, or one naming such a constant (`const T = mod.T`). A member of a type, read
/// by name or `@field`, is its declaration, never a field of a value.
fn namesType(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    var at_file = file;
    var at = Facts.ungrouped(&c.project.at(file).file.tree, node);
    for (0..8) |_| {
        // One not known to name a type may be a value.
        const decl = switch (try c.facts.definition(at_file, at)) {
            .decl => |d| d,
            .none, .unknown => return false,
        };
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        if (record.kind != .variable) return false;
        const written = &c.project.at(decl.file).file.tree;
        const variable = written.fullVarDecl(record.node) orelse return false;
        if (written.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
        const init = Facts.ungrouped(written, variable.ast.init_node.unwrap() orelse return false);
        // A module's or Zig file's namespace; a ZON file's value is none.
        if (Facts.importKind(written, init)) |kind| return kind == .namespace;
        for ([_][]const u8{ "@This", "@TypeOf", "@Type", "@Int", "@Float", "@Vector", "@Pointer", "@Fn", "@Tuple", "@Struct", "@Union", "@Enum", "@EnumLiteral" }) |name| {
            if (Facts.isBuiltin(written, init, name)) return true;
        }
        var buffer: [1]Ast.Node.Index = undefined;
        if (written.fullCall(&buffer, init)) |call| return typeFunction(c, decl.file, call.ast.fn_expr);
        at_file = decl.file;
        at = init;
    }
    return false;
}

/// Whether `callee` names a function declared to return `type`.
fn typeFunction(c: *Context, file: Project.FileId, callee: Ast.Node.Index) Context.Error!bool {
    const found = switch (try c.facts.definition(file, callee)) {
        .decl => |d| d,
        .none, .unknown => return false,
    };
    const function = c.project.at(found.file).model.declarations[@backingInt(found.index)];
    if (function.kind != .function) return false;
    const tree = &c.project.at(found.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, function.node) orelse return false;
    return c.facts.typeIsType(found.file, proto.ast.return_type.unwrap() orelse return false);
}
