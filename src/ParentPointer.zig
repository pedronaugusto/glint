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
    if (args.len != 2 or tree.nodeTag(args[0]) != .string_literal) return null;
    const name = std.zig.string_literal.parseAlloc(c.allocator, tree.tokenSlice(tree.nodeMainToken(args[0]))) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const parent = pointee(try resultType(c, c.file, node)) orelse return null;
    const field = c.facts.member(parent, name) orelse return null;
    const record = c.project.at(field.file).model.declarations[@backingInt(field.index)];
    if (record.kind != .field) return null;
    const written = &c.project.at(field.file).file.tree;
    const declared = (written.fullContainerField(record.node) orelse return null).ast.type_expr.unwrap() orelse return null;
    const kind = held(try c.facts.resolve(field.file, declared)) orelse return null;
    const field_of: Field = .{ .parent = parent, .name = name };
    const pointer = strip(tree, args[1]);
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
    const inner = strip(tree, args[0]);
    if (!isBuiltin(tree, inner, "@fieldParentPtr")) return .open;
    return cleared(c, inner);
}

const Field = struct { parent: Facts.Container, name: []const u8 };

fn interfaceField(c: *Context, node: Ast.Node.Index, pointer: Ast.Node.Index, field: Field, kind: Facts.Container) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    // `p` is the converting function's own parameter, a pointer to F's type.
    if (tree.nodeTag(pointer) != .identifier) return false;
    const index = (model.reference(pointer) orelse return false).declaration orelse return false;
    const param = model.declarations[@backingInt(index)];
    if (param.kind != .parameter) return false;
    const function = enclosingFunction(tree, model, node) orelse return false;
    if (!parameterOf(tree, function, param.token)) return false;
    const param_type = tree.fullPtrType(param.node) orelse return false;
    const interface = held(try c.facts.resolve(c.file, param_type.ast.child_type)) orelse return false;
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
        const declared = (tree.fullContainerField(decl.node) orelse continue).ast.type_expr.unwrap() orelse continue;
        if (functionPointer(tree, declared)) |proto| {
            const given = (try interfaceParameters(c, kind.file, proto, kind)) orelse return false;
            if (!try readsCalledOnSelf(c, decl.name, kind, false, given)) return false;
            continue;
        }
        // A vtable: each of its functions, read through this field.
        const pointer = tree.fullPtrType(declared) orelse continue;
        const table = held(try c.facts.resolve(kind.file, pointer.ast.child_type)) orelse continue;
        const inner = c.project.at(table.file);
        for (inner.model.declarations) |entry| {
            if (entry.kind != .field or entry.scope != table.scope) continue;
            const entry_type = (inner.file.tree.fullContainerField(entry.node) orelse continue).ast.type_expr.unwrap() orelse continue;
            const proto = functionPointer(&inner.file.tree, entry_type) orelse continue;
            const given = (try interfaceParameters(c, table.file, proto, kind)) orelse return false;
            if (!try readsCalledOnSelf(c, entry.name, table, true, given)) return false;
        }
        // The vtable itself read out (`w.vtable = s.interface.vtable`) carries its functions
        // to another interface: each read must take a function of it, or compare it.
        if (!try tableReadInPlace(c, decl.name, kind)) return false;
    }
    // `@field(x, "vtable")` or `@field(x, "f")` of an interface names its functions too. One
    // written (`@field(out, name) = d`) installs, which the conversion it reaches judges.
    for (c.project.sources) |*each| {
        if (!try c.facts.program(each.id)) continue;
        const file_tree = &each.file.tree;
        for (file_tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (!isBuiltin(file_tree, node, "@field")) continue;
            if (each.model.parentOf(node)) |parent| if (file_tree.nodeTag(parent) == .assign and file_tree.nodeData(parent).node_and_node[0] == node) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(file_tree, node, &buffer);
            if (args.len != 2) continue;
            const receiver = try c.facts.resolve(each.id, args[0]);
            if (receiver != .unknown and !isParent(receiver, kind)) continue;
            if (receiver == .unknown and (generic(file_tree, &each.model, node) or try namesType(c, each.id, args[0]))) continue;
            for (source.model.declarations) |decl| {
                if (decl.kind != .field or decl.scope != kind.scope) continue;
                const declared = (tree.fullContainerField(decl.node) orelse continue).ast.type_expr.unwrap() orelse continue;
                if (functionPointer(tree, declared)) |_| {
                    // A member of it read, indexed or iterated: no function pointer.
                    if (notFunction(file_tree, &each.model, node)) continue;
                } else if (tree.fullPtrType(declared) == null) continue;
                if (try namedBy(c, file_tree, &each.model, args[1], decl.name)) return false;
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
        const model = &c.project.at(use.file).model;
        const receiver = tree.nodeData(use.node).node_and_token[0];
        const value = try c.facts.resolve(use.file, receiver);
        if (value == .unknown) {
            if (try namesType(c, use.file, receiver) or generic(tree, model, use.node)) continue;
            return false;
        }
        if (!isParent(value, kind)) continue;
        if (!tableInPlace(tree, model, use.node)) return false;
    }
    return true;
}

/// Whether the vtable read `use` reads a function of the table, is written, or is compared.
fn tableInPlace(tree: *const Ast, model: *const Model, use: Ast.Node.Index) bool {
    const parent = model.parentOf(use) orelse return false;
    return switch (tree.nodeTag(parent)) {
        .field_access, .equal_equal, .bang_equal => true,
        .assign => tree.nodeData(parent).node_and_node[0] == use,
        else => false,
    };
}

/// The positions of the parameters of the function type `proto` that are pointers to `kind`,
/// as bits; null where a type there does not resolve, or a position is past 63.
fn interfaceParameters(c: *Context, file: Project.FileId, proto: Ast.Node.Index, kind: Facts.Container) Context.Error!?u64 {
    const tree = &c.project.at(file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const full = tree.fullFnProto(&buffer, proto) orelse return null;
    var positions: u64 = 0;
    var it = full.iterate(tree);
    var position: u7 = 0;
    while (it.next()) |param| : (position += 1) {
        if (position == 64) return null;
        const declared = param.type_expr orelse return null;
        const value = try c.facts.resolve(file, declared);
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
        const model = &c.project.at(use.file).model;
        const receiver = tree.nodeData(use.node).node_and_token[0];
        const value = try c.facts.resolve(use.file, receiver);
        if (value == .unknown) {
            if (try namesType(c, use.file, receiver) or notFunction(tree, model, use.node) or generic(tree, model, use.node)) continue;
            return false;
        }
        if (!isParent(value, holder)) continue;
        if (!calledOnSelf(tree, model, use.node, through, given)) return false;
    }
    return true;
}

/// Whether the member read `use` is no function pointer: something reads a member of it,
/// indexes, slices or iterates it, which Zig allows no function pointer.
fn notFunction(tree: *const Ast, model: *const Model, use: Ast.Node.Index) bool {
    const parent = model.parentOf(use) orelse return false;
    if (tree.fullFor(parent)) |loop| return std.mem.findScalar(Ast.Node.Index, loop.ast.inputs, use) != null;
    return switch (tree.nodeTag(parent)) {
        .field_access => tree.nodeData(parent).node_and_token[0] == use,
        .array_access => tree.nodeData(parent).node_and_node[0] == use,
        .slice, .slice_open, .slice_sentinel => true,
        else => false,
    };
}

/// Whether the function read `use` (`x.f`, `x.vtable.f` where `through`) is called at once,
/// `.?` unwrapping it at most, with the interface it was read from at each position `given`;
/// or captured from its optional (`if (x.f) |f|`) and the capture only called so, on an
/// interface a parameter, a capture or a constant names, which nothing changes in between.
fn calledOnSelf(tree: *const Ast, model: *const Model, use: Ast.Node.Index, through: bool, given: u64) bool {
    const receiver = tree.nodeData(use).node_and_token[0];
    // The interface: the receiver, or what the vtable was read from.
    var interface = receiver;
    if (through) {
        if (tree.nodeTag(receiver) != .field_access) return false;
        interface = tree.nodeData(receiver).node_and_token[0];
    }
    var callee = use;
    var outer = model.parentOf(use) orelse return false;
    if (tree.fullIf(outer)) |branch| {
        if (branch.ast.cond_expr != use or !fixed(tree, model, interface)) return false;
        const payload = branch.payload_token orelse return false;
        if (tree.tokenTag(payload) == .asterisk) return false;
        for (model.declarations, 0..) |decl, d| {
            if (decl.kind != .capture or decl.node != outer or decl.token != payload) continue;
            const index: Model.Declaration.Id = @fromBackingInt(@intCast(d));
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                if (tag != .identifier) continue;
                const reference: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if ((model.reference(reference) orelse continue).declaration != index) continue;
                var call_buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&call_buffer, model.parentOf(reference) orelse return false) orelse return false;
                if (call.ast.fn_expr != reference or !givenSelf(tree, call, interface, given)) return false;
            }
            return true;
        }
        return false;
    }
    if (tree.nodeTag(outer) == .unwrap_optional) {
        callee = outer;
        outer = model.parentOf(outer) orelse return false;
    }
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, outer) orelse return false;
    if (call.ast.fn_expr != callee) return false;
    return givenSelf(tree, call, interface, given);
}

/// Whether `call` is given `interface` at each position `given`, by value or by address.
fn givenSelf(tree: *const Ast, call: Ast.full.Call, interface: Ast.Node.Index, given: u64) bool {
    for (call.ast.params, 0..) |param, position| {
        if (position >= 64 or given & (@as(u64, 1) << @intCast(position)) == 0) continue;
        var argument = strip(tree, param);
        if (tree.nodeTag(argument) == .address_of) argument = strip(tree, tree.nodeData(argument).node);
        if (!sameTokens(tree, argument, interface)) return false;
    }
    return call.ast.params.len >= 64 or given >> @intCast(call.ast.params.len) == 0;
}

/// The member read an `if` captured, where `node` names that capture (`if (x.f) |f|`).
fn capturedRead(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Ast.Node.Index {
    if (tree.nodeTag(node) != .identifier) return null;
    const index = (model.reference(node) orelse return null).declaration orelse return null;
    const decl = model.declarations[@backingInt(index)];
    if (decl.kind != .capture) return null;
    const branch = tree.fullIf(decl.node) orelse return null;
    if (branch.payload_token != decl.token or tree.nodeTag(branch.ast.cond_expr) != .field_access) return null;
    return branch.ast.cond_expr;
}

/// Whether `node` names a parameter, a capture or a constant: what it holds cannot change.
fn fixed(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    const index = (model.reference(node) orelse return false).declaration orelse return false;
    const decl = model.declarations[@backingInt(index)];
    return switch (decl.kind) {
        .parameter, .capture => true,
        .variable => if (tree.fullVarDecl(decl.node)) |variable| tree.tokenTag(variable.ast.mut_token) == .keyword_const else false,
        .function, .field => false,
    };
}

/// The function type a pointer to a function, or an optional one, points at.
fn functionPointer(tree: *const Ast, kind: Ast.Node.Index) ?Ast.Node.Index {
    var at = kind;
    if (tree.nodeTag(at) == .optional_type) at = tree.nodeData(at).node;
    const pointer = tree.fullPtrType(at) orelse return null;
    var buffer: [1]Ast.Node.Index = undefined;
    return if (tree.fullFnProto(&buffer, pointer.ast.child_type) != null) pointer.ast.child_type else null;
}

/// Whether two expressions are spelled the same, token by token.
fn sameTokens(tree: *const Ast, a: Ast.Node.Index, b: Ast.Node.Index) bool {
    const first_a = tree.firstToken(a);
    const first_b = tree.firstToken(b);
    const count = tree.lastToken(a) - first_a;
    if (tree.lastToken(b) - first_b != count) return false;
    for (0..count + 1) |i| {
        if (!std.mem.eql(u8, tree.tokenSlice(first_a + @as(Ast.TokenIndex, @intCast(i))), tree.tokenSlice(first_b + @as(Ast.TokenIndex, @intCast(i))))) return false;
    }
    return true;
}

/// Whether the parameter at `token` of `function` is only ever given a pointer to C.F: the
/// function is not `pub`, and named only where C's own code installs it into C.F's value; or
/// only called directly, that parameter given the same parameter of a function that is so, a
/// pointer to F's type (a helper the installed functions share, at most four calls deep).
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
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tag) {
            .identifier => if ((model.reference(node) orelse continue).declaration != decl) continue,
            .field_access => {
                const found = (try c.facts.definition(c.file, node)) orelse continue;
                if (found.file != c.file or found.index != decl) continue;
                // Called on a value, it is handed that value first: no helper's call.
                if (try c.facts.resolve(c.file, tree.nodeData(node).node_and_token[0]) != .container) return false;
            },
            else => continue,
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, model.parentOf(node) orelse return false) orelse return false;
        if (call.ast.fn_expr != node or position >= call.ast.params.len) return false;
        const arg = strip(tree, call.ast.params[position]);
        if (tree.nodeTag(arg) != .identifier) return false;
        const given = model.declarations[@backingInt((model.reference(arg) orelse return false).declaration orelse return false)];
        if (given.kind != .parameter) return false;
        const caller = enclosingFunction(tree, model, node) orelse return false;
        if (!parameterOf(tree, caller, given.token)) return false;
        const given_type = tree.fullPtrType(given.node) orelse return false;
        if (!same(held(try c.facts.resolve(c.file, given_type.ast.child_type)) orelse return false, kind)) return false;
        if (!try reachedOnlyInstalled(c, caller, given.token, field, kind, depth + 1)) return false;
        called = true;
    }
    return called;
}

/// Whether every reference to `decl` in the checked file installs it into C.F's value, from
/// C's file; up to `through` constants that are not `pub` may stand between (a vtable, a
/// struct holding one), each named only so in turn.
fn namedOnlyInstalling(c: *Context, decl: Model.Declaration.Id, field: Field, through: u8) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var named = false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const refers = switch (tag) {
            .identifier => if (model.reference(node)) |ref| ref.declaration == decl else false,
            .field_access => if (try c.facts.definition(c.file, node)) |found| found.file == c.file and found.index == decl else false,
            else => false,
        };
        if (!refers) continue;
        named = true;
        if (!try installs(c, node, field, through)) return false;
    }
    // `@field(C, "f")` names it too, and installs nothing this follows.
    const record = model.declarations[@backingInt(decl)];
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (!isBuiltin(tree, node, "@field")) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        if (args.len != 2) continue;
        switch (try c.facts.resolve(c.file, args[0])) {
            .container, .instance => |container| if (container.file != c.file or container.scope != record.scope) continue,
            .unknown => {},
            else => continue,
        }
        if (try namedBy(c, tree, model, args[1], record.name)) return false;
    }
    return named;
}

/// Whether the expression around `reference` puts it into C.F's value, in C's file: through
/// literals and addresses up to `.F = …` of a literal that is a C or `x.F = …` of a C, or,
/// while `through` allows, into a container constant that is not `pub` whose every reference
/// does so. The function is not `pub`: only its own file names it.
fn installs(c: *Context, reference: Ast.Node.Index, field: Field, through: u8) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var at = reference;
    for (0..16) |_| {
        const parent = model.parentOf(at) orelse return false;
        switch (tree.nodeTag(parent)) {
            .address_of, .grouped_expression => {
                at = parent;
                continue;
            },
            .assign => {
                const target, const value = tree.nodeData(parent).node_and_node;
                if (value != at or tree.nodeTag(target) != .field_access) return false;
                if (!std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(target).node_and_token[1])), field.name)) return false;
                if (!isParent(try c.facts.resolve(c.file, tree.nodeData(target).node_and_token[0]), field.parent)) return false;
                return field.parent.file == c.file;
            },
            else => {},
        }
        // `if (c) f else null`: what is installed is it or the other branch's value.
        if (tree.fullIf(parent)) |branch| {
            if (branch.ast.cond_expr == at or branch.payload_token != null or branch.error_token != null) return false;
            at = parent;
            continue;
        }
        // C.F's own default value, declared in C.
        if (tree.fullContainerField(parent)) |declared| {
            if (declared.ast.value_expr.unwrap() != at) return false;
            if (!std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(declared.ast.main_token)), field.name)) return false;
            return field.parent.file == c.file and model.parentOf(parent) == model.scopes[@backingInt(field.parent.scope)].node;
        }
        if (tree.fullVarDecl(parent)) |variable| {
            if (through == 0 or variable.ast.init_node.unwrap() != at) return false;
            if (variable.visib_token != null or tree.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
            if (!containerLevel(tree, model, parent)) return false;
            const constant = for (model.declarations, 0..) |each, d| {
                if (each.node == parent and each.kind == .variable) break @as(Model.Declaration.Id, @fromBackingInt(@intCast(d)));
            } else return false;
            return namedOnlyInstalling(c, constant, field, through - 1);
        }
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullStructInit(&buffer, parent)) |literal| {
            if (std.mem.findScalar(Ast.Node.Index, literal.ast.fields, at) == null) return false;
            // `.F = …` of a literal C is: the install.
            const first = tree.firstToken(at);
            if (first >= 2 and tree.tokenTag(first - 1) == .equal and tree.tokenTag(first - 2) == .identifier and
                std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(first - 2)), field.name))
            {
                const container = if (literal.ast.type_expr.unwrap()) |t| held(try c.facts.resolve(c.file, t)) else try c.facts.resultContainer(c.file, parent);
                if (container) |made| if (same(made, field.parent)) return field.parent.file == c.file;
            }
            at = parent;
            continue;
        }
        if (tree.fullArrayInit(&buffer, parent) != null) {
            at = parent;
            continue;
        }
        return false;
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
        const model = &c.project.at(use.file).model;
        const receiver = try c.facts.resolve(use.file, tree.nodeData(use.node).node_and_token[0]);
        if (receiver != .unknown and !isParent(receiver, field.parent)) continue;
        if (receiver == .unknown) {
            if (try namesType(c, use.file, tree.nodeData(use.node).node_and_token[0]) or generic(tree, model, use.node)) continue;
            return false;
        }
        const parent = model.parentOf(use.node) orelse return false;
        switch (tree.nodeTag(parent)) {
            .address_of => if (!try follow.stays(use.file, parent)) return false,
            .assign => if (tree.nodeData(parent).node_and_node[0] != use.node) return false,
            .field_access => if (!try follow.member(use.file, parent)) return false,
            else => return false,
        }
    }
    // `@field(x, "F")` names it too; written whole, as `x.F = v`, it stays in place.
    for (c.project.sources) |*source| {
        if (!try c.facts.program(source.id)) continue;
        const tree = &source.file.tree;
        for (tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (!isBuiltin(tree, node, "@field")) continue;
            if (source.model.parentOf(node)) |parent| if (tree.nodeTag(parent) == .assign and tree.nodeData(parent).node_and_node[0] == node) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 2) continue;
            // Of another type, it names none of C's fields.
            const receiver = try c.facts.resolve(source.id, args[0]);
            if (receiver != .unknown and !isParent(receiver, field.parent)) continue;
            if (receiver == .unknown and (generic(tree, &source.model, node) or try namesType(c, source.id, args[0]))) continue;
            if (try namedBy(c, tree, &source.model, args[1], field.name)) return false;
        }
    }
    const model = &c.project.at(c.file).model;
    const tree = &c.project.at(c.file).file.tree;
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .parameter) continue;
        const declared = tree.fullPtrType(decl.node) orelse continue;
        const to = held(try c.facts.resolve(c.file, declared.ast.child_type)) orelse continue;
        if (!same(to, kind)) continue;
        if (!try follow.local(c.file, @fromBackingInt(@intCast(d)))) return false;
    }
    return true;
}

/// Whether a `@field` name may be `name`: it is spelled so, or computed as the program compiles
/// to what may be. A capture of a `for` over a list of string literals, written in place or a
/// constant's, takes only those.
fn namedBy(c: *Context, tree: *const Ast, model: *const Model, spelling: Ast.Node.Index, name: []const u8) Context.Error!bool {
    if (tree.nodeTag(spelling) == .string_literal) return spelledAs(c, tree, spelling, name);
    var buffer: [2]Ast.Node.Index = undefined;
    const names = literalNames(tree, model, spelling, &buffer) orelse return true;
    for (names) |each| if (try spelledAs(c, tree, each, name)) return true;
    return false;
}

/// Whether the string literal `literal` spells `name`; one that does not parse may.
fn spelledAs(c: *Context, tree: *const Ast, literal: Ast.Node.Index, name: []const u8) Context.Error!bool {
    const spelled = std.zig.string_literal.parseAlloc(c.allocator, tree.tokenSlice(tree.nodeMainToken(literal))) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return true,
    };
    return std.mem.eql(u8, spelled, name);
}

/// The string literals the capture `node` names may be: those of the list a `for` takes it
/// from, written in place (`.{ "a", "b" }`) or a constant's (`const names = [_][]const u8{ … }`).
fn literalNames(tree: *const Ast, model: *const Model, node: Ast.Node.Index, buffer: *[2]Ast.Node.Index) ?[]const Ast.Node.Index {
    if (tree.nodeTag(node) != .identifier) return null;
    const decl = model.declarations[@backingInt((model.reference(node) orelse return null).declaration orelse return null)];
    if (decl.kind != .capture or tree.tokenTag(decl.token -| 1) == .asterisk) return null;
    const loop = tree.fullFor(decl.node) orelse return null;
    const position = Model.capturePosition(tree, loop, decl.token) orelse return null;
    if (position >= loop.ast.inputs.len) return null;
    var list = strip(tree, loop.ast.inputs[position]);
    if (tree.nodeTag(list) == .address_of) list = strip(tree, tree.nodeData(list).node);
    if (tree.nodeTag(list) == .identifier) {
        const named = model.declarations[@backingInt((model.reference(list) orelse return null).declaration orelse return null)];
        if (named.kind != .variable) return null;
        const variable = tree.fullVarDecl(named.node) orelse return null;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
        list = strip(tree, variable.ast.init_node.unwrap() orelse return null);
    }
    const literal = tree.fullArrayInit(buffer, list) orelse return null;
    for (literal.ast.elements) |each| if (tree.nodeTag(each) != .string_literal) return null;
    return literal.ast.elements;
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

    /// Whether the pointer `node` in `file` stays one wherever its value goes.
    fn stays(f: *Follow, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
        f.steps += 1;
        if (f.steps > 4096) return false;
        const c = f.c;
        const tree = &c.project.at(file).file.tree;
        const model = &c.project.at(file).model;
        const parent = model.parentOf(node) orelse return false;
        switch (tree.nodeTag(parent)) {
            .grouped_expression, .@"try", .unwrap_optional, .@"orelse", .@"catch" => return f.stays(file, parent),
            .equal_equal, .bang_equal => return true,
            .deref => {
                // `p.*.x` reads or calls a part; `p.* = v` writes the whole in place.
                const up = model.parentOf(parent) orelse return false;
                if (tree.nodeTag(up) == .assign and tree.nodeData(up).node_and_node[0] == parent) return true;
                if (tree.nodeTag(up) == .field_access) return f.member(file, up);
                return false;
            },
            .field_access => return f.member(file, parent),
            .assign => {
                const target, const value = tree.nodeData(parent).node_and_node;
                // The pointer itself replaced.
                if (target == node) return true;
                if (value != node) return false;
                return f.stored(file, target);
            },
            .@"return" => return f.returned(file, parent),
            // A switch prong's value, a labeled block's: what the switch or block is.
            .switch_case_one, .switch_case, .switch_case_inline_one, .switch_case_inline => return f.stays(file, model.parentOf(parent) orelse return false),
            .@"break" => return f.stays(file, labeled(tree, model, parent) orelse return false),
            else => {},
        }
        if (isBuiltin(tree, parent, "@fieldParentPtr")) return true;
        if (isBuiltin(tree, parent, "@as")) {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, parent, &buffer);
            if (args.len != 2 or args[1] != node or !f.pointer(try c.facts.resolve(file, args[0]))) return false;
            return f.stays(file, parent);
        }
        if (tree.fullIf(parent)) |branch| {
            if (branch.ast.cond_expr == node) return f.tested(file, parent, branch.payload_token, branch.error_token);
            return f.stays(file, parent);
        }
        if (tree.fullWhile(parent)) |loop| {
            if (loop.ast.cond_expr == node) return f.tested(file, parent, loop.payload_token, loop.error_token);
            return false;
        }
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, parent)) |call| {
            if (call.ast.fn_expr == node) return false;
            const position = std.mem.findScalar(Ast.Node.Index, call.ast.params, node) orelse return false;
            // Through a function pointer field (`o.vtable.see(o, n)`): what the interface's
            // functions are handed, each installed one's parameter followed with its file's.
            var callee = call.ast.fn_expr;
            if (tree.nodeTag(callee) == .unwrap_optional) callee = tree.nodeData(callee).node_and_token[0];
            if (capturedRead(tree, model, callee)) |read| callee = read;
            if (tree.nodeTag(callee) == .field_access) if (try c.facts.definition(file, callee)) |slot| {
                const record = c.project.at(slot.file).model.declarations[@backingInt(slot.index)];
                if (record.kind == .field) {
                    const slot_tree = &c.project.at(slot.file).file.tree;
                    const declared = (slot_tree.fullContainerField(record.node) orelse return false).ast.type_expr.unwrap() orelse return false;
                    const proto = functionPointer(slot_tree, declared) orelse return false;
                    const given = (try interfaceParameters(c, slot.file, proto, f.kind)) orelse return false;
                    return position < 64 and given & (@as(u64, 1) << @intCast(position)) != 0;
                }
            };
            var index = position;
            if (tree.nodeTag(call.ast.fn_expr) == .field_access) switch (try c.facts.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
                .instance, .pointer, .optional => index += 1,
                else => {},
            };
            const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
                .function => |function| function,
                else => return false,
            };
            return f.handed((try c.facts.origin(decl)) orelse decl, index);
        }
        if (tree.fullVarDecl(parent)) |variable| {
            if (variable.ast.init_node.unwrap() != node) return false;
            if (variable.ast.type_node.unwrap()) |declared| if (!f.pointer(try c.facts.resolve(file, declared))) return false;
            for (model.declarations, 0..) |each, d| {
                if (each.node == parent and each.kind == .variable) return f.local(file, @fromBackingInt(@intCast(d)));
            }
            return false;
        }
        // `.{ .w = p }`: the field of the literal's type it is put in.
        var fields: [2]Ast.Node.Index = undefined;
        if (tree.fullStructInit(&fields, parent)) |literal| {
            if (std.mem.findScalar(Ast.Node.Index, literal.ast.fields, node) == null) return false;
            const first = tree.firstToken(node);
            if (first < 2 or tree.tokenTag(first - 1) != .equal or tree.tokenTag(first - 2) != .identifier) return false;
            const container = (if (literal.ast.type_expr.unwrap()) |t| held(try c.facts.resolve(file, t)) else try c.facts.resultContainer(file, parent)) orelse return false;
            const decl = c.facts.member(container, try Model.identifier(c.allocator, tree.tokenSlice(first - 2))) orelse return false;
            return f.field(decl);
        }
        return false;
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
            .pointer => |to| to.*,
            .optional => |inner| return f.pointer(inner.*),
            else => return false,
        };
        return if (held(to)) |container| same(container, f.kind) else false;
    }

    /// `p.name`: a part of the interface, read or written; or a method called with it, which
    /// takes it by pointer: std's, or the program's, followed into.
    fn member(f: *Follow, file: Project.FileId, access: Ast.Node.Index) Context.Error!bool {
        const c = f.c;
        const tree = &c.project.at(file).file.tree;
        const model = &c.project.at(file).model;
        const decl = (try c.facts.definition(file, access)) orelse return false;
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        if (record.kind == .field) return true;
        if (record.kind != .function) return false;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, model.parentOf(access) orelse return false) orelse return false;
        if (call.ast.fn_expr != access) return false;
        return f.handed((try c.facts.origin(decl)) orelse decl, 0);
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
        const tree = &c.project.at(file).file.tree;
        const model = &c.project.at(file).model;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const ref = model.reference(node) orelse continue;
            if (ref.declaration != index) continue;
            if (!try f.stays(file, node)) return false;
        }
        return true;
    }

    /// `x = p` where `x` is a local or a field of the interface's pointer type.
    fn stored(f: *Follow, file: Project.FileId, target: Ast.Node.Index) Context.Error!bool {
        const c = f.c;
        const tree = &c.project.at(file).file.tree;
        if (tree.nodeTag(target) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) return true;
        const decl = (try c.facts.definition(file, target)) orelse return false;
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
        const declared = (c.project.at(decl.file).file.tree.fullContainerField(record.node) orelse return false).ast.type_expr.unwrap() orelse return false;
        if (!f.pointer(try c.facts.resolve(decl.file, declared))) return false;
        // A field others outside the program can read may carry it anywhere.
        if (record.public) return false;
        for (try c.facts.memberUses(record.name)) |use| {
            const found = (try c.facts.definition(use.file, use.node)) orelse {
                const tree = &c.project.at(use.file).file.tree;
                if (try namesType(c, use.file, tree.nodeData(use.node).node_and_token[0])) continue;
                return false;
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
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const each: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const refers = switch (tag) {
                .identifier => if (model.reference(each)) |ref| ref.declaration == index else false,
                .field_access => if (try c.facts.definition(file, each)) |found| found.file == file and found.index == index else false,
                else => false,
            };
            if (!refers) continue;
            var call_buffer: [1]Ast.Node.Index = undefined;
            const call_node = model.parentOf(each) orelse return false;
            const call = tree.fullCall(&call_buffer, call_node) orelse return false;
            if (call.ast.fn_expr != each) return false;
            if (!try f.stays(file, call_node)) return false;
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
                for (call.ast.params, 0..) |argument, position| {
                    const shape = (try k.carries(source.id, argument, 0)) orelse continue;
                    verdict = worst(verdict, try k.handedOn(source.id, call, position, shape, true));
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
        const at = strip(tree, node);
        if (tree.nodeTag(at) == .address_of) return k.carries(file, tree.nodeData(at).node, depth + 1);
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
            .pointer, .optional, .error_union => |inner| try k.holds(inner.*, depth + 1),
            .array => |element| if (try k.holds(element.*, depth + 1) != null) .held else null,
            else => null,
        };
    }

    /// A call given a carrier at `position`: the callee's parameter there followed through its
    /// body. A parameter of the program's own that is a C or a pointer to one is read by the
    /// program-wide checks already.
    fn handedOn(k: *Carry, file: Project.FileId, call: Ast.full.Call, position: usize, shape: Shape, from_program: bool) Context.Error!Verdict {
        const c = k.c;
        const tree = &c.project.at(file).file.tree;
        var index = position;
        if (tree.nodeTag(call.ast.fn_expr) == .field_access) switch (try c.facts.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
            .instance, .pointer, .optional => index += 1,
            else => {},
        };
        const found = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
            .function => |function| function,
            else => return .undecided,
        };
        const decl = (try c.facts.origin(found)) orelse found;
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
        const tree = &c.project.at(file).file.tree;
        const model = &c.project.at(file).model;
        var verdict: Verdict = .shown;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const ref = model.reference(node) orelse continue;
            if (ref.declaration != index) continue;
            verdict = worst(verdict, try k.goes(file, node, shape));
            if (verdict == .open) return .open;
        }
        return verdict;
    }

    /// Where the carrier `node` goes.
    fn goes(k: *Carry, file: Project.FileId, node: Ast.Node.Index, shape: Shape) Context.Error!Verdict {
        k.steps += 1;
        if (k.steps > budget) return .undecided;
        const c = k.c;
        const tree = &c.project.at(file).file.tree;
        const model = &c.project.at(file).model;
        const parent = model.parentOf(node) orelse return .undecided;
        switch (tree.nodeTag(parent)) {
            .grouped_expression, .@"try", .unwrap_optional, .@"orelse", .@"catch", .deref, .address_of => return k.goes(file, parent, shape),
            .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal => return .shown,
            .add, .sub, .mul, .div, .mod, .shl, .shr, .bit_and, .bit_or, .bit_xor, .add_wrap, .sub_wrap, .mul_wrap, .add_sat, .sub_sat, .mul_sat, .bool_and, .bool_or, .bool_not, .negation, .bit_not => return .shown,
            .field_access => return k.member(file, parent, shape),
            .assign => {
                const target, const value = tree.nodeData(parent).node_and_node;
                if (target == node) return .shown;
                if (value != node) return .undecided;
                return k.into(file, target, shape);
            },
            else => {},
        }
        if (tree.fullVarDecl(parent)) |variable| {
            if (variable.ast.init_node.unwrap() != node) return .shown;
            for (model.declarations, 0..) |each, d| {
                if (each.node == parent and each.kind == .variable) return k.local(file, @fromBackingInt(@intCast(d)), shape);
            }
            return .undecided;
        }
        if (tree.fullIf(parent)) |branch| {
            if (branch.ast.cond_expr != node) return k.goes(file, parent, shape);
            return k.captured(file, parent, branch.payload_token, branch.error_token, shape);
        }
        if (tree.fullWhile(parent)) |loop| {
            if (loop.ast.cond_expr != node) return .undecided;
            return k.captured(file, parent, loop.payload_token, loop.error_token, shape);
        }
        if (tree.fullFor(parent)) |loop| {
            if (std.mem.findScalar(Ast.Node.Index, loop.ast.inputs, node) == null) return .undecided;
            // Its elements, each captured: any of them may be a C.
            var verdict: Verdict = .shown;
            for (model.declarations, 0..) |each, d| {
                if (each.kind != .capture or each.node != parent) continue;
                verdict = worst(verdict, try k.local(file, @fromBackingInt(@intCast(d)), .held));
            }
            return verdict;
        }
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, parent)) |call| {
            if (call.ast.fn_expr == node) return .undecided;
            const position = std.mem.findScalar(Ast.Node.Index, call.ast.params, node) orelse return .undecided;
            return k.handedOn(file, call, position, shape, false);
        }
        var literal_buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullStructInit(&literal_buffer, parent) != null or tree.fullArrayInit(&literal_buffer, parent) != null) return k.goes(file, parent, .held);
        switch (tree.nodeTag(parent)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
            else => return .undecided,
        }
        const name = tree.tokenSlice(tree.nodeMainToken(parent));
        for ([_][]const u8{ "@TypeOf", "@sizeOf", "@alignOf", "@bitSizeOf", "@hasField", "@hasDecl", "@intFromPtr" }) |typed| {
            if (std.mem.eql(u8, name, typed)) return .shown;
        }
        if (std.mem.eql(u8, name, "@as")) return k.goes(file, parent, shape);
        if (std.mem.eql(u8, name, "@field")) {
            var args_buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, parent, &args_buffer);
            if (args.len != 2 or args[0] != node) return .shown;
            return k.part(file, parent, args[1], shape);
        }
        if (std.mem.eql(u8, name, "@call")) return .undecided;
        return .open;
    }

    /// `if (x) |v|`, `while (x) |v|`: the capture holds the carrier; an error's capture does
    /// not.
    fn captured(k: *Carry, file: Project.FileId, owner: Ast.Node.Index, payload: ?Ast.TokenIndex, error_token: ?Ast.TokenIndex, shape: Shape) Context.Error!Verdict {
        _ = error_token;
        const token = payload orelse return .shown;
        const tree = &k.c.project.at(file).file.tree;
        const name = if (tree.tokenTag(token) == .asterisk) token + 1 else token;
        for (k.c.project.at(file).model.declarations, 0..) |each, d| {
            if (each.kind == .capture and each.node == owner and each.token == name) return k.local(file, @fromBackingInt(@intCast(d)), shape);
        }
        return .undecided;
    }

    /// `x = carrier`: into a local, followed; into a carrier's own place (`a.* = b.*`), a C
    /// where a C was; elsewhere undecided.
    fn into(k: *Carry, file: Project.FileId, target: Ast.Node.Index, shape: Shape) Context.Error!Verdict {
        const c = k.c;
        const tree = &c.project.at(file).file.tree;
        const model = &c.project.at(file).model;
        if (tree.nodeTag(target) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) return .shown;
        var root = strip(tree, target);
        while (true) switch (tree.nodeTag(root)) {
            .deref, .unwrap_optional => root = strip(tree, tree.nodeData(root).node),
            .field_access => root = strip(tree, tree.nodeData(root).node_and_token[0]),
            .array_access => root = strip(tree, tree.nodeData(root).node_and_node[0]),
            else => break,
        };
        if (tree.nodeTag(root) != .identifier) return .undecided;
        const index = (model.reference(root) orelse return .undecided).declaration orelse return .undecided;
        if (root == target) return k.local(file, index, shape);
        if (k.seen.contains(.{ .{ .file = file, .index = index }, .whole }) or k.seen.contains(.{ .{ .file = file, .index = index }, .held })) return .shown;
        return .undecided;
    }

    /// `carrier.name`: C.F where it may be it, and what else the part may hold.
    fn member(k: *Carry, file: Project.FileId, access: Ast.Node.Index, shape: Shape) Context.Error!Verdict {
        const tree = &k.c.project.at(file).file.tree;
        const name = try Model.identifier(k.c.allocator, tree.tokenSlice(tree.nodeData(access).node_and_token[1]));
        return k.named(file, access, name, shape);
    }

    /// `@field(carrier, name)`: a name computed as the program compiles may be any part.
    fn part(k: *Carry, file: Project.FileId, access: Ast.Node.Index, spelling: Ast.Node.Index, shape: Shape) Context.Error!Verdict {
        const c = k.c;
        const tree = &c.project.at(file).file.tree;
        if (tree.nodeTag(spelling) == .string_literal) {
            const spelled = std.zig.string_literal.parseAlloc(c.allocator, tree.tokenSlice(tree.nodeMainToken(spelling))) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return k.anyPart(file, access),
            };
            return k.named(file, access, spelled, shape);
        }
        return k.anyPart(file, access);
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
                const declared = (c.project.at(decl.file).file.tree.fullContainerField(record.node) orelse return .undecided).ast.type_expr.unwrap() orelse return .undecided;
                const value = try c.facts.resolve(decl.file, declared);
                if (value == .unknown) return k.goes(file, access, .held);
                return if (try k.holds(value, 0)) |inner| k.goes(file, access, inner) else .shown;
            },
        }
    }

    /// C.F itself, reached in a body: its address followed, a part of it read or a method of
    /// it called, written whole; anything else copies it.
    fn interface(k: *Carry, file: Project.FileId, access: Ast.Node.Index) Context.Error!Verdict {
        const tree = &k.c.project.at(file).file.tree;
        const parent = k.c.project.at(file).model.parentOf(access) orelse return .undecided;
        switch (tree.nodeTag(parent)) {
            .address_of => return if (try k.follow.stays(file, parent)) .shown else .open,
            .field_access => {
                // Its part or method by name on F's type: in a generic, `x` does not resolve.
                const c = k.c;
                const name = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(parent).node_and_token[1]));
                const decl = c.facts.member(k.follow.kind, name) orelse return .open;
                const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
                if (record.kind == .field) return .shown;
                if (record.kind != .function) return .open;
                var buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buffer, k.c.project.at(file).model.parentOf(parent) orelse return .open) orelse return .open;
                if (call.ast.fn_expr != parent) return .open;
                return if (try k.follow.handed((try c.facts.origin(decl)) orelse decl, 0)) .shown else .open;
            },
            .assign => return if (tree.nodeData(parent).node_and_node[0] == access) .shown else .open,
            else => return .open,
        }
    }
};

/// Whether `decl` is a function of std's `mem.Allocator`.
fn allocatorMethod(c: *Context, decl: Facts.Decl) Context.Error!bool {
    if (!try c.facts.standard(decl.file)) return false;
    const scope = c.project.at(decl.file).model.declarations[@backingInt(decl.index)].scope;
    for ((try Governed.declarations(c, "std", "mem.Allocator")) orelse &.{}) |found| {
        const allocator = held(try c.facts.declaration(found)) orelse continue;
        if (allocator.file == decl.file and allocator.scope == scope) return true;
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
    const kinds = try interfaces(c);
    if (kinds.len == 0) return;
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tag) {
            .identifier, .field_access, .deref, .array_access, .unwrap_optional, .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma, .call_one, .call_one_comma, .call, .call_comma => {},
            else => continue,
        }
        const token = tree.nodeMainToken(node);
        if (c.inTest(token)) continue;
        if (isBuiltin(tree, node, "@field")) if (try namesFunction(c, kinds, node)) {
            try c.at(rule, token, "@field naming an interface's function or vtable: a function its implementation installed, read out, recovers its parent by @fieldParentPtr from whatever it is then given");
            continue;
        };
        const value = try c.facts.resolve(c.file, node);
        const called = switch (tag) {
            .call_one, .call_one_comma, .call, .call_comma => true,
            else => false,
        };
        // A call's result is a value of its own; a copy that made it was flagged where made.
        if (!called) if (held(value)) |container| if (value == .instance and interfaceOf(kinds, container) != null and copied(tree, model, node) and !try ownStorage(c, node)) {
            try c.at(rule, token, "a copy of an interface: its functions recover the struct around it by @fieldParentPtr, which a copy is not in; keep it where it was installed and pass its address");
            continue;
        };
        if (tag == .field_access and !try readInPlace(c, kinds, node)) {
            try c.at(rule, token, "an interface's function or vtable read out, or called on another interface: it recovers its parent by @fieldParentPtr from the interface it is given");
            continue;
        }
        const target = if (value == .instance) value.instance else pointee(value) orelse continue;
        const kind = interfaceOf(kinds, target) orelse continue;
        if (!try handedInPlace(c, kind, node)) {
            try c.at(rule, token, "an interface handed to a function that may copy it or read its functions out: its functions recover the struct around it by @fieldParentPtr");
        }
    }
}

/// Whether `node` names a variable, a parameter or a capture: storage of its own, never the
/// field of a struct its functions recover, so a copy of it breaks nothing. The copy that put
/// an installed interface there was flagged where it was made.
fn ownStorage(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const decl = (try c.facts.definition(c.file, node)) orelse return false;
    return switch (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind) {
        .variable, .parameter, .capture => true,
        .function, .field => false,
    };
}

const Interfaces = struct { kinds: ?[]const Facts.Container = null, handed: std.AutoHashMapUnmanaged(struct { Facts.Container, Facts.Decl, usize }, bool) = .empty };

/// std's `Io.Writer` and `Io.Reader`, and each type a loaded file outside std converts its own
/// parameter from by `@fieldParentPtr`.
fn interfaces(c: *Context) Context.Error![]const Facts.Container {
    const known = try c.facts.memo(Interfaces);
    if (known.kinds) |kinds| return kinds;
    var kinds: std.ArrayList(Facts.Container) = .empty;
    for ([_][]const u8{ "Io.Writer", "Io.Reader" }) |path| {
        for ((try Governed.declarations(c, "std", path)) orelse &.{}) |found| {
            if (held(try c.facts.declaration(found))) |kind| if (interfaceOf(kinds.items, kind) == null) try kinds.append(c.allocator, kind);
        }
    }
    for (c.project.sources) |*source| {
        if (source.file.status != .parsed or try c.facts.standard(source.id)) continue;
        const tree = &source.file.tree;
        for (tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (!isBuiltin(tree, node, "@fieldParentPtr")) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 2) continue;
            const pointer = strip(tree, args[1]);
            if (tree.nodeTag(pointer) != .identifier) continue;
            const index = (source.model.reference(pointer) orelse continue).declaration orelse continue;
            const param = source.model.declarations[@backingInt(index)];
            if (param.kind != .parameter) continue;
            const declared = tree.fullPtrType(param.node) orelse continue;
            const kind = held(try c.facts.resolve(source.id, declared.ast.child_type)) orelse continue;
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
fn copied(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var at = node;
    while (true) {
        const parent = model.parentOf(at) orelse return false;
        switch (tree.nodeTag(parent)) {
            .grouped_expression, .@"try", .@"orelse", .@"catch" => {
                at = parent;
                continue;
            },
            .field_access, .address_of, .unwrap_optional, .deref, .equal_equal, .bang_equal => return false,
            .assign => {
                const target, _ = tree.nodeData(parent).node_and_node;
                if (target == at) return false;
                return !(tree.nodeTag(target) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_"));
            },
            .switch_case_one, .switch_case, .switch_case_inline_one, .switch_case_inline => {
                at = model.parentOf(parent) orelse return true;
                continue;
            },
            else => {},
        }
        if (tree.fullVarDecl(parent)) |variable| return variable.ast.init_node.unwrap() == at;
        if (tree.fullIf(parent)) |branch| {
            if (branch.ast.cond_expr == at) return branch.payload_token != null and tree.tokenTag(branch.payload_token.?) != .asterisk;
            at = parent;
            continue;
        }
        if (tree.fullWhile(parent)) |loop| return loop.ast.cond_expr == at and loop.payload_token != null and tree.tokenTag(loop.payload_token.?) != .asterisk;
        switch (tree.nodeTag(parent)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(parent));
                for ([_][]const u8{ "@TypeOf", "@sizeOf", "@alignOf", "@bitSizeOf", "@hasField", "@hasDecl", "@field" }) |typed| {
                    if (std.mem.eql(u8, name, typed)) return false;
                }
                if (std.mem.eql(u8, name, "@as")) {
                    at = parent;
                    continue;
                }
                return true;
            },
            else => return true,
        }
    }
}

/// Whether the member read `access` of an interface (or of its vtable) is in place: a function
/// called then and there on the interface it was read from, a vtable read for a function of it,
/// compared or written. Another member, or another type's, is not one of these.
fn readInPlace(c: *Context, kinds: []const Facts.Container, access: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    // A function written in is an installation, which the conversion it reaches judges.
    if (model.parentOf(access)) |parent| if (tree.nodeTag(parent) == .assign and tree.nodeData(parent).node_and_node[0] == access) return true;
    const receiver = try c.facts.resolve(c.file, tree.nodeData(access).node_and_token[0]);
    const name = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(access).node_and_token[1]));
    for (kinds) |kind| {
        for (try functions(c, kind)) |slot| {
            if (!std.mem.eql(u8, slot.name, name) or !isParent(receiver, slot.holder)) continue;
            if (slot.table) return tableInPlace(tree, model, access);
            const given = slot.given orelse return false;
            if (!calledOnSelf(tree, model, access, slot.through, given)) return false;
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
    const known = try c.facts.memo(Slots);
    if (known.found.get(kind)) |slots| return slots;
    var slots: std.ArrayList(Slot) = .empty;
    const source = c.project.at(kind.file);
    const tree = &source.file.tree;
    for (source.model.declarations) |decl| {
        if (decl.kind != .field or decl.scope != kind.scope) continue;
        const declared = (tree.fullContainerField(decl.node) orelse continue).ast.type_expr.unwrap() orelse continue;
        if (functionPointer(tree, declared)) |proto| {
            try slots.append(c.allocator, .{ .holder = kind, .name = decl.name, .given = try interfaceParameters(c, kind.file, proto, kind) });
            continue;
        }
        const pointer = tree.fullPtrType(declared) orelse continue;
        const table = held(try c.facts.resolve(kind.file, pointer.ast.child_type)) orelse continue;
        const inner = c.project.at(table.file);
        var any = false;
        for (inner.model.declarations) |entry| {
            if (entry.kind != .field or entry.scope != table.scope) continue;
            const entry_type = (inner.file.tree.fullContainerField(entry.node) orelse continue).ast.type_expr.unwrap() orelse continue;
            const proto = functionPointer(&inner.file.tree, entry_type) orelse continue;
            try slots.append(c.allocator, .{ .holder = table, .name = entry.name, .through = true, .given = try interfaceParameters(c, table.file, proto, kind) });
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
        if (try namedBy(c, tree, &c.project.at(c.file).model, args[1], slot.name)) return true;
    };
    return false;
}

/// Whether an interface (or a pointer to one) `node` is handed only where it stays in place:
/// to a function of a file this run checks whose parameter is a pointer to it, whose copies
/// the contract reports there; to any other function (std's, a dependency's, the program's
/// in a file not checked) whose body is followed and keeps it so. A part read, a function of it called on itself, is no handing.
fn handedInPlace(c: *Context, kind: Facts.Container, value: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    // `&w.*`, `(w)`: the same interface handed.
    var node = value;
    var parent = model.parentOf(node) orelse return true;
    while (tree.nodeTag(parent) == .grouped_expression or tree.nodeTag(parent) == .address_of) {
        node = parent;
        parent = model.parentOf(node) orelse return true;
    }
    var decl: Facts.Decl = undefined;
    var index: usize = 0;
    if (tree.nodeTag(parent) == .field_access) {
        if (tree.nodeData(parent).node_and_token[0] != node) return true;
        const found = (try c.facts.definition(c.file, parent)) orelse return true;
        if (c.project.at(found.file).model.declarations[@backingInt(found.index)].kind != .function) return true;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, model.parentOf(parent) orelse return true) orelse return true;
        if (call.ast.fn_expr != parent) return true;
        decl = (try c.facts.origin(found)) orelse found;
    } else {
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, parent) orelse return true;
        const position = std.mem.findScalar(Ast.Node.Index, call.ast.params, node) orelse return true;
        index = position;
        if (tree.nodeTag(call.ast.fn_expr) == .field_access) switch (try c.facts.resolve(c.file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
            .instance, .pointer, .optional => index += 1,
            else => {},
        };
        // Through a function field: read where it is, by `readInPlace`.
        decl = switch (try c.facts.resolve(c.file, call.ast.fn_expr)) {
            .function => |function| (try c.facts.origin(function)) orelse function,
            else => return true,
        };
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
                    if (follow.pointer(declared_value)) return true;
                    if (declared_value == .container and same(declared_value.container, kind)) return true;
                }
                break;
            };
        }
    }
    const known = try c.facts.memo(Interfaces);
    const key = .{ kind, decl, index };
    if (known.handed.get(key)) |kept| return kept;
    const kept = try follow.handed(decl, index);
    try known.handed.put(c.allocator, key, kept);
    return kept;
}

const List = enum { doubly, singly };

fn listNode(c: *Context, pointer: Ast.Node.Index, field: Field, kind: Facts.Container) Context.Error!bool {
    const list = (try stdList(c, kind, "Node")) orelse return false;
    const source = (try nodeSource(c, c.file, pointer, field, list, null, 0)) orelse return false;
    if (source == .same) return false;
    if (!try insertsOnlyParents(c, field, list, source)) return false;
    if (!try listsInPlace(c, list)) return false;
    return addressedOnly(c, field, kind, false);
}

/// Which of std's lists `container` is the `member` of (`Node`), or the list type itself
/// where `member` is empty.
fn stdList(c: *Context, container: Facts.Container, member: []const u8) Context.Error!?List {
    for ([_]struct { List, []const u8 }{ .{ .doubly, "DoublyLinkedList" }, .{ .singly, "SinglyLinkedList" } }) |each| {
        const path = if (member.len == 0) each[1] else try c.allocator.print("{s}.{s}", .{ each[1], member });
        for ((try Governed.declarations(c, "std", path)) orelse &.{}) |found| {
            if (held(try c.facts.declaration(found))) |known| if (same(known, container)) return each[0];
        }
    }
    return null;
}

/// The list a node comes out of: the declaration holding it (a field or a variable); `.any`
/// for a node that is `&c.F` of a C itself; `.same` for the local being traced, read again
/// (`while (it) |n| : (it = n.next)`), which adds nothing.
const Source = union(enum) { any, same, list: Facts.Decl };

/// Where the node `node` comes from, if it is `&c.F` of a C or out of one list: its `first` or
/// `last`, `popFirst()` or `popLast()`, or a node's `next` or `prev` out of the same list, also
/// through a local whose every value is one, or a capture of one.
fn nodeSource(c: *Context, file: Project.FileId, node: Ast.Node.Index, field: Field, list: List, tracing: ?Model.Declaration.Id, depth: usize) Context.Error!?Source {
    if (depth == 8) return null;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const at = strip(tree, node);
    switch (tree.nodeTag(at)) {
        .address_of => {
            const operand = tree.nodeData(at).node;
            if (tree.nodeTag(operand) != .field_access) return null;
            if (!std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(operand).node_and_token[1])), field.name)) return null;
            if (!isParent(try c.facts.resolve(file, tree.nodeData(operand).node_and_token[0]), field.parent)) return null;
            return .any;
        },
        .unwrap_optional => return nodeSource(c, file, tree.nodeData(at).node_and_token[0], field, list, tracing, depth + 1),
        .@"orelse" => {
            // `x orelse return null`: the other side leaves, adding nothing; a value there is a
            // node too.
            const value, const otherwise = tree.nodeData(at).node_and_node;
            const found = (try nodeSource(c, file, value, field, list, tracing, depth + 1)) orelse return null;
            switch (tree.nodeTag(otherwise)) {
                .@"return", .unreachable_literal, .@"break", .@"continue" => return found,
                else => return joinSource(found, (try nodeSource(c, file, otherwise, field, list, tracing, depth + 1)) orelse return null),
            }
        },
        .field_access => {
            const receiver, const member_token = tree.nodeData(at).node_and_token;
            const member = try Model.identifier(c.allocator, tree.tokenSlice(member_token));
            if (std.mem.eql(u8, member, "first") or std.mem.eql(u8, member, "last")) return listOf(c, file, receiver, list);
            if (std.mem.eql(u8, member, "next") or std.mem.eql(u8, member, "prev")) {
                const from = (try nodeSource(c, file, receiver, field, list, tracing, depth + 1)) orelse return null;
                // A C's own node is in no list this shows.
                return if (from == .any) null else from;
            }
            return null;
        },
        .call_one, .call_one_comma => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, at).?; // unreachable: the tag is a call's
            if (call.ast.params.len != 0 or tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
            const receiver, const member_token = tree.nodeData(call.ast.fn_expr).node_and_token;
            const member = try Model.identifier(c.allocator, tree.tokenSlice(member_token));
            if (!std.mem.eql(u8, member, "popFirst") and !std.mem.eql(u8, member, "popLast")) return null;
            return listOf(c, file, receiver, list);
        },
        .identifier => {
            const index = (model.reference(at) orelse return null).declaration orelse return null;
            if (tracing == index) return .same;
            const decl = model.declarations[@backingInt(index)];
            if (decl.kind == .capture) {
                // `while (it) |n|` or `if (x) |n|`: what the condition gives.
                const condition = if (tree.fullWhile(decl.node)) |loop| loop.ast.cond_expr else if (tree.fullIf(decl.node)) |branch| branch.ast.cond_expr else return null;
                return nodeSource(c, file, condition, field, list, tracing, depth + 1);
            }
            if (decl.kind != .variable) return null;
            const variable = tree.fullVarDecl(decl.node) orelse return null;
            var found: ?Source = null;
            if (variable.ast.init_node.unwrap()) |init| found = (try nodeSource(c, file, init, field, list, index, depth + 1)) orelse return null;
            // Every later value put in it, out of the same list; its address writes it
            // wherever that goes.
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                if (tag == .address_of) {
                    const operand = strip(tree, tree.nodeData(@fromBackingInt(@intCast(i))).node);
                    if (tree.nodeTag(operand) == .identifier) if (model.reference(operand)) |ref| if (ref.declaration == index) return null;
                    continue;
                }
                if (tag != .assign) continue;
                const target, const value = tree.nodeData(@fromBackingInt(@intCast(i))).node_and_node;
                if (tree.nodeTag(target) != .identifier) continue;
                const ref = model.reference(target) orelse continue;
                if (ref.declaration != index) continue;
                const next = (try nodeSource(c, file, value, field, list, index, depth + 1)) orelse return null;
                found = joinSource(found, next) orelse return null;
            }
            return found;
        },
        else => return null,
    }
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
        .pointer => |to| held(to.*) orelse return null,
        else => return null,
    };
    if (try stdList(c, container, "") != list) return null;
    const decl = (try c.facts.definition(file, receiver)) orelse return null;
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
    const inserts: []const []const u8 = switch (list) {
        .doubly => &.{ "append", "prepend", "insertAfter", "insertBefore", "concatByMoving" },
        .singly => &.{ "prepend", "insertAfter" },
    };
    const links = [_][]const u8{ "first", "last", "next", "prev" };
    for (inserts) |method| for (try c.facts.memberUses(method)) |use| {
        const tree = &c.project.at(use.file).file.tree;
        const model = &c.project.at(use.file).model;
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
        const outer = model.parentOf(use.node) orelse return false;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, outer) orelse return false;
        if (call.ast.fn_expr != use.node) return false;
        if (std.mem.eql(u8, method, "concatByMoving")) {
            if (of != .node and try mayBe(c, use.file, receiver, source)) return false;
            continue;
        }
        if (of == .list and !try mayBe(c, use.file, receiver, source)) continue;
        // The node put in: the last argument.
        if (call.ast.params.len == 0) return false;
        const inserted = (try nodeSource(c, use.file, call.ast.params[call.ast.params.len - 1], field, list, null, 0)) orelse return false;
        if (inserted != .any) return false;
    };
    for (links) |link| for (try c.facts.memberUses(link)) |use| {
        const tree = &c.project.at(use.file).file.tree;
        const model = &c.project.at(use.file).model;
        if ((try receiverKind(c, use.file, tree.nodeData(use.node).node_and_token[0], list)) == null) continue;
        const parent = model.parentOf(use.node) orelse continue;
        // A link's address writes it wherever that goes.
        if (tree.nodeTag(parent) == .address_of) return false;
        if (tree.nodeTag(parent) != .assign or tree.nodeData(parent).node_and_node[0] != use.node) continue;
        const value = strip(tree, tree.nodeData(parent).node_and_node[1]);
        if (tree.nodeTag(value) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "null")) continue;
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
            if (!isBuiltin(tree, node, "@field")) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 2) continue;
            if ((try receiverKind(c, each.id, args[0], list)) == null) continue;
            for (links ++ [_][]const u8{ "append", "prepend", "insertAfter", "insertBefore", "concatByMoving" }) |name| {
                if (try namedBy(c, tree, &each.model, args[1], name)) return false;
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
                    const plain = strip(tree, value);
                    if (is_link and !(tree.nodeTag(plain) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(plain)), "null"))) linked = true;
                }
                if (!linked) continue;
                const container = if (literal.ast.type_expr.unwrap()) |t| held(try c.facts.resolve(file, t)) else try c.facts.resultContainer(file, node);
                const made = container orelse return false;
                if (try stdList(c, made, "") == list or try stdList(c, made, "Node") == list) return false;
                continue;
            }
            switch (tag) {
                .identifier, .field_access, .deref, .array_access, .unwrap_optional => {},
                else => continue,
            }
            const value = try c.facts.resolve(file, node);
            const container = switch (value) {
                .instance => |container| container,
                else => continue,
            };
            if (try stdList(c, container, "") != list and try stdList(c, container, "Node") != list) continue;
            // In place: its address, a member of it, a whole write to it.
            const parent = model.parentOf(node) orelse return false;
            switch (tree.nodeTag(parent)) {
                .address_of, .field_access => continue,
                .assign => {
                    const target, const assigned = tree.nodeData(parent).node_and_node;
                    if (target != node) return false;
                    var literal_buffer: [2]Ast.Node.Index = undefined;
                    if (tree.fullStructInit(&literal_buffer, strip(tree, assigned)) == null) return false;
                },
                else => {
                    // Its declaration names it, as its type, not as a value.
                    if (tree.nodeTag(node) == .identifier) {
                        const ref = model.reference(node) orelse return false;
                        const index = ref.declaration orelse return false;
                        if (model.declarations[@backingInt(index)].node == parent) continue;
                    }
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
            if (try stdList(c, container, "") == list or try stdList(c, container, "Node") == list) return false;
        }
        // A local of either initialised from a place, not a literal.
        for (model.declarations) |decl| {
            if (decl.kind != .variable) continue;
            const variable = tree.fullVarDecl(decl.node) orelse continue;
            const init = strip(tree, variable.ast.init_node.unwrap() orelse continue);
            var literal_buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullStructInit(&literal_buffer, init) != null) continue;
            const container = switch (try c.facts.resolve(file, init)) {
                .instance => |container| container,
                else => continue,
            };
            if (try stdList(c, container, "") == list or try stdList(c, container, "Node") == list) return false;
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
        .pointer => |to| held(to.*),
        else => null,
    } orelse return null;
    if (try stdList(c, container, "") == list) return .list;
    if (try stdList(c, container, "Node") == list) return .node;
    return null;
}

/// Whether the list expression `receiver` may be `source`'s list: it is, or it names no other
/// field or variable.
fn mayBe(c: *Context, file: Project.FileId, receiver: Ast.Node.Index, source: Source) Context.Error!bool {
    const decl = (try c.facts.definition(file, receiver)) orelse return true;
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
        switch (tree.nodeTag(parent)) {
            .grouped_expression, .@"try" => {
                at = parent;
                continue;
            },
            .@"return" => {
                const function = enclosingFunction(tree, model, parent) orelse return .{ .unknown = .unresolved };
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, function) orelse return .{ .unknown = .unresolved };
                return c.facts.resolve(file, proto.ast.return_type.unwrap() orelse return .{ .unknown = .unresolved });
            },
            .assign => {
                const target, const value = tree.nodeData(parent).node_and_node;
                if (value != at) return .{ .unknown = .unresolved };
                return c.facts.resolve(file, target);
            },
            else => {},
        }
        if (isBuiltin(tree, parent, "@alignCast")) {
            at = parent;
            continue;
        }
        if (isBuiltin(tree, parent, "@as")) {
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
        .pointer => |to| held(to.*),
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
fn isParent(value: Facts.Value, parent: Facts.Container) bool {
    return switch (value) {
        .container, .instance => |container| same(container, parent),
        .pointer => |to| isParent(to.*, parent),
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
fn generic(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var up = model.parentOf(node);
    while (up) |parent| : (up = model.parentOf(parent)) {
        if (tree.nodeTag(parent) != .fn_decl) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(parent).node_and_node[0]) orelse continue;
        if (proto.ast.return_type.unwrap()) |returned| if (typeKeyword(tree, returned)) return true;
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            if (param.anytype_ellipsis3 != null) return true;
            if (param.comptime_noalias) |token| if (tree.tokenTag(token) == .keyword_comptime) return true;
            if (param.type_expr) |declared| if (typeKeyword(tree, declared)) return true;
        }
    }
    return false;
}

fn typeKeyword(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "type");
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

/// Whether `node` names a type, not a value: a constant an `@import` of a file makes, a
/// builtin that makes a type (`@Enum`, `@Struct`, …), or a call of a function declared to
/// return `type`, or one naming such a constant (`const T = mod.T`). A member of a type, read
/// by name or `@field`, is its declaration, never a field of a value.
fn namesType(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    var at_file = file;
    var at = strip(&c.project.at(file).file.tree, node);
    for (0..8) |_| {
        const tree = &c.project.at(at_file).file.tree;
        const decl = switch (tree.nodeTag(at)) {
            .identifier, .field_access => (try c.facts.definition(at_file, at)) orelse return false,
            else => return false,
        };
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        if (record.kind != .variable) return false;
        const written = &c.project.at(decl.file).file.tree;
        const variable = written.fullVarDecl(record.node) orelse return false;
        if (written.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
        const init = strip(written, variable.ast.init_node.unwrap() orelse return false);
        if (isBuiltin(written, init, "@import")) {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(written, init, &buffer);
            return args.len == 1 and written.nodeTag(args[0]) == .string_literal;
        }
        for ([_][]const u8{ "@This", "@TypeOf", "@Type", "@Int", "@Float", "@Vector", "@Pointer", "@Fn", "@Tuple", "@Struct", "@Union", "@Enum", "@EnumLiteral" }) |name| {
            if (isBuiltin(written, init, name)) return true;
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
    const found = (try c.facts.definition(file, callee)) orelse return false;
    const function = c.project.at(found.file).model.declarations[@backingInt(found.index)];
    if (function.kind != .function) return false;
    const tree = &c.project.at(found.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, function.node) orelse return false;
    return typeKeyword(tree, proto.ast.return_type.unwrap() orelse return false);
}

/// The labeled block a `break :label value` gives its value to.
fn labeled(tree: *const Ast, model: *const Model, jump: Ast.Node.Index) ?Ast.Node.Index {
    const label = tree.tokenSlice(tree.nodeData(jump).opt_token_and_opt_node[0].unwrap() orelse return null);
    var at = jump;
    while (model.parentOf(at)) |up| : (at = up) {
        switch (tree.nodeTag(up)) {
            .fn_decl => return null,
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                const brace = tree.nodeMainToken(up);
                if (brace >= 2 and tree.tokenTag(brace - 1) == .colon and std.mem.eql(u8, tree.tokenSlice(brace - 2), label)) return up;
            },
            else => {},
        }
    }
    return null;
}

fn strip(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = node;
    while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
    return at;
}

fn isBuiltin(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name),
        else => false,
    };
}
