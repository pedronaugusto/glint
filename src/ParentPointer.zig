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
const Ast = std.zig.Ast;

/// Whether the `@fieldParentPtr` call `node` in the checked file is one of the two shapes.
pub fn cleared(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 2 or tree.nodeTag(args[0]) != .string_literal) return false;
    const name = std.zig.string_literal.parseAlloc(c.allocator, tree.tokenSlice(tree.nodeMainToken(args[0]))) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const parent = pointee(try resultType(c, c.file, node)) orelse return false;
    const field = c.facts.member(parent, name) orelse return false;
    const record = c.project.at(field.file).model.declarations[@backingInt(field.index)];
    if (record.kind != .field) return false;
    const written = &c.project.at(field.file).file.tree;
    const declared = (written.fullContainerField(record.node) orelse return false).ast.type_expr.unwrap() orelse return false;
    const kind = held(try c.facts.resolve(field.file, declared)) orelse return false;
    const field_of: Field = .{ .parent = parent, .name = name };
    const pointer = strip(tree, args[1]);
    if (try interfaceField(c, node, pointer, field_of, kind)) return true;
    if (try listNode(c, pointer, field_of, kind)) return true;
    return false;
}

/// Whether the `@alignCast` call `node` is around a cleared `@fieldParentPtr`: its alignment
/// is the parent's, which that shape shows the pointer is.
pub fn clearedAlignment(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 1) return false;
    const inner = strip(tree, args[0]);
    if (!isBuiltin(tree, inner, "@fieldParentPtr")) return false;
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
    return addressedOnly(c, field);
}

/// Whether every read in the package of a function an interface of type `kind` holds (a
/// function pointer field of it, or of the vtable it points at) calls it there and then on the
/// interface it was read from (`h.f(h)`, `x.F.f(&x.F)`, `w.vtable.drain(w, …)`, `i.f.?(io, i)`):
/// each parameter the function takes as a pointer to `kind` is given that interface. A function
/// read out and called on another pointer converts that pointer as though it were C.F's. A
/// read whose receiver does not resolve may be one, unless it is an import's name.
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
    }
    return true;
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
            if (namespace(tree, model, receiver)) continue;
            return false;
        }
        if (!isParent(value, holder)) continue;
        var callee = use.node;
        var outer = model.parentOf(use.node) orelse return false;
        if (tree.nodeTag(outer) == .unwrap_optional) {
            callee = outer;
            outer = model.parentOf(outer) orelse return false;
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, outer) orelse return false;
        if (call.ast.fn_expr != callee) return false;
        // The interface: the receiver, or what the vtable was read from.
        var interface = receiver;
        if (through) {
            if (tree.nodeTag(receiver) != .field_access) return false;
            interface = tree.nodeData(receiver).node_and_token[0];
        }
        for (call.ast.params, 0..) |param, position| {
            if (position >= 64 or given & (@as(u64, 1) << @intCast(position)) == 0) continue;
            var argument = strip(tree, param);
            if (tree.nodeTag(argument) == .address_of) argument = strip(tree, tree.nodeData(argument).node);
            if (!sameTokens(tree, argument, interface)) return false;
        }
        if (call.ast.params.len < 64 and given >> @intCast(call.ast.params.len) != 0) return false;
    }
    return true;
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
/// method of it that takes it by pointer: none copies it. A use whose receiver does not resolve
/// may be C's, and shows nothing, unless it is an import's name.
fn addressedOnly(c: *Context, field: Field) Context.Error!bool {
    for (try c.facts.memberUses(field.name)) |use| {
        const tree = &c.project.at(use.file).file.tree;
        const model = &c.project.at(use.file).model;
        const receiver = try c.facts.resolve(use.file, tree.nodeData(use.node).node_and_token[0]);
        if (receiver != .unknown and !isParent(receiver, field.parent)) continue;
        if (receiver == .unknown) {
            if (namespace(tree, model, tree.nodeData(use.node).node_and_token[0])) continue;
            return false;
        }
        const parent = model.parentOf(use.node) orelse return false;
        switch (tree.nodeTag(parent)) {
            .address_of => continue,
            .assign => if (tree.nodeData(parent).node_and_node[0] == use.node) continue else return false,
            .field_access => {
                // A part read (`x.F.end`), or a method that takes C.F by pointer.
                const outer = model.parentOf(parent) orelse continue;
                var buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buffer, outer) orelse continue;
                if (call.ast.fn_expr != parent) continue;
                // A function pointer field of it called (`x.F.f(&x.F)`) is a part read.
                if (try fieldOfInterface(c, use.file, parent)) continue;
                if (!try takesPointer(c, use.file, parent)) return false;
            },
            else => return false,
        }
    }
    // `@field(x, "F")` names it too.
    for (c.project.sources) |*source| {
        if (!source.input.selected) continue;
        const tree = &source.file.tree;
        for (tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (!isBuiltin(tree, node, "@field")) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 2) continue;
            // Of another type, it names none of C's fields.
            const receiver = try c.facts.resolve(source.id, args[0]);
            if (receiver != .unknown and !isParent(receiver, field.parent)) continue;
            // A name computed as the program compiles may be F.
            if (tree.nodeTag(args[1]) != .string_literal) return false;
            const spelled = std.zig.string_literal.parseAlloc(c.allocator, tree.tokenSlice(tree.nodeMainToken(args[1]))) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
            if (std.mem.eql(u8, spelled, field.name)) return false;
        }
    }
    return true;
}

/// Whether the member access `callee` names a field, not a method: what it reads is that part.
fn fieldOfInterface(c: *Context, file: Project.FileId, callee: Ast.Node.Index) Context.Error!bool {
    const decl = (try c.facts.definition(file, callee)) orelse return false;
    return c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind == .field;
}

/// Whether the method `callee` (a member access called) takes its receiver by pointer.
fn takesPointer(c: *Context, file: Project.FileId, callee: Ast.Node.Index) Context.Error!bool {
    const decl = (try c.facts.definition(file, callee)) orelse return false;
    const origin = (try c.facts.origin(decl)) orelse return false;
    const record = c.project.at(origin.file).model.declarations[@backingInt(origin.index)];
    if (record.kind != .function) return false;
    const written = &c.project.at(origin.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = written.fullFnProto(&buffer, record.node) orelse return false;
    var it = proto.iterate(written);
    const first = it.next() orelse return false;
    return written.fullPtrType(first.type_expr orelse return false) != null;
}

const List = enum { doubly, singly };

fn listNode(c: *Context, pointer: Ast.Node.Index, field: Field, kind: Facts.Container) Context.Error!bool {
    const list = (try stdList(c, kind, "Node")) orelse return false;
    const source = (try nodeSource(c, c.file, pointer, field, list, null, 0)) orelse return false;
    if (source == .same) return false;
    if (!try insertsOnlyParents(c, field, list, source)) return false;
    return addressedOnly(c, field);
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
            // Every later value put in it, out of the same list.
            for (tree.nodes.items(.tag), 0..) |tag, i| {
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
/// `insertAfter`) and a store to a list's or node's links. A list moved into another
/// (`concatByMoving`) is shown nothing of.
fn insertsOnlyParents(c: *Context, field: Field, list: List, source: Source) Context.Error!bool {
    const inserts: []const []const u8 = switch (list) {
        .doubly => &.{ "append", "prepend", "insertAfter", "insertBefore", "concatByMoving" },
        .singly => &.{ "prepend", "insertAfter" },
    };
    for (inserts) |method| for (try c.facts.memberUses(method)) |use| {
        const tree = &c.project.at(use.file).file.tree;
        const model = &c.project.at(use.file).model;
        const outer = model.parentOf(use.node) orelse continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, outer) orelse continue;
        if (call.ast.fn_expr != use.node) continue;
        // Which it is, by its receiver's type: std's list or its node; a receiver that does
        // not resolve may be either.
        const receiver = tree.nodeData(use.node).node_and_token[0];
        const of = (try receiverKind(c, use.file, receiver, list)) orelse continue;
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
    for ([_][]const u8{ "first", "last", "next", "prev" }) |link| for (try c.facts.memberUses(link)) |use| {
        const tree = &c.project.at(use.file).file.tree;
        const model = &c.project.at(use.file).model;
        const parent = model.parentOf(use.node) orelse continue;
        if (tree.nodeTag(parent) != .assign or tree.nodeData(parent).node_and_node[0] != use.node) continue;
        if ((try receiverKind(c, use.file, tree.nodeData(use.node).node_and_token[0], list)) == null) continue;
        const value = strip(tree, tree.nodeData(parent).node_and_node[1]);
        if (tree.nodeTag(value) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "null")) continue;
        const stored = (try nodeSource(c, use.file, value, field, list, null, 0)) orelse return false;
        if (stored == .same) return false;
    };
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

/// Whether `node` names an `@import` directly (`const options = @import("options")`): a
/// member of it is a declaration of that file or module, never a field of a value, whether or
/// not the import resolves.
fn namespace(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    const at = strip(tree, node);
    if (tree.nodeTag(at) != .identifier) return false;
    const index = (model.reference(at) orelse return false).declaration orelse return false;
    const record = model.declarations[@backingInt(index)];
    if (record.kind != .variable) return false;
    const variable = tree.fullVarDecl(record.node) orelse return false;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
    const init = strip(tree, variable.ast.init_node.unwrap() orelse return false);
    if (!isBuiltin(tree, init, "@import")) return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, init, &buffer);
    return args.len == 1 and tree.nodeTag(args[0]) == .string_literal;
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
