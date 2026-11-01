//! The danger rules read from the shapes of declarations and statements (designs/aegis.md §7):
//! a std resource without its one owner (A015), two identifying integers of one type meeting
//! in one signature (A016), an enum state its holder moves by hand on its own value (A017),
//! and a borrow of a std container's storage kept in a field (A014). A019's `undefined` reads
//! are `Undefined.zig`'s.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Contract = @import("AegisContract.zig");
const Danger = @import("Danger.zig");
const Taint = @import("Taint.zig");
const Program = @import("Program.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;

/// The std resources A015 reads, as `containersOf` finds them.
const resource_paths = [_][]const u8{ "Io.File", "Io.Dir", "Io.net.Stream", "Io.net.Server", "process.Child" };

/// A015: a std resource held by value in a field the program owns it through, or returned by the
/// program's own function, outside aegis's `own.Owned`. A field is an owner where the program
/// releases what it holds (`released`) or writes into it what is no view (`owns`): an owner a
/// call made. One the program only fills with what it is given, and never releases, is a borrow,
/// as `borrow().*` of an `own.Owned` is. A tuple's field, named by position only, is no
/// declaration to follow: each one by value is flagged where it is written. A function each of
/// whose returns reads what is already held hands over no owner (`views`).
pub fn ownership(c: *Context, rule: Rule) Context.Error!void {
    const resources = try containersOf(c, rule, &resource_paths);
    if (resources.len == 0) return;
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var vtable: ?Facts.Container = null;
    var looked = false;
    for (model.declarations, 0..) |decl, index| {
        if (c.inTest(decl.token)) continue;
        const written: Ast.Node.Index = switch (decl.kind) {
            .field => (tree.fullContainerField(decl.node) orelse continue).ast.type_expr.unwrap() orelse continue,
            .function => blk: {
                var buffer: [1]Ast.Node.Index = undefined;
                break :blk (tree.fullFnProto(&buffer, decl.node) orelse continue).ast.return_type.unwrap() orelse continue;
            },
            else => continue,
        };
        const which = switch (try heldBy(c, resources, try c.facts.resolve(c.file, written), 0)) {
            .resource => |which| which,
            .other => continue,
            // A generic's parameter: each binding's, judged where it is bound (`bindings`).
            .generic => continue,
            .unknown => {
                try c.undecided(rule, tree.tokenStart(decl.token), .unresolved, if (decl.kind == .field) "a field whose type does not resolve may hold a std resource by value" else "a function whose result type does not resolve may return a std resource by value");
                continue;
            },
        };
        const id: Model.Declaration.Id = @fromBackingInt(@intCast(index));
        const why = switch (decl.kind) {
            .field => try owns(c, rule, resources, .{ .file = c.file, .scope = decl.scope }, c.file, decl, decl.token) orelse continue,
            else => why: {
                if (try views(c, resources, .{ .file = c.file, .index = id }, 0, null)) continue;
                if (!looked) {
                    vtable = (try containersOf(c, rule, &.{"Io.VTable"}))[0];
                    looked = true;
                }
                if (try implements(c, id, vtable)) continue;
                break :why "that is no view of one held: an owner handed over";
            },
        };
        const what = if (decl.kind == .field) "field" else "function";
        const how = if (decl.kind == .field) "holds" else "returns";
        try c.at(rule, decl.token, try c.allocator.print("{s} '{s}' {s} a std.{s} by value {s}: aegis own.Owned names its one owner and checks it is released once; a borrow of it is its borrow().*, which is never released", .{ what, decl.name, how, resource_paths[which], why }));
    }
    try foreign(c, rule, resources);
    try bindings(c, rule, resources, &resource_paths);
}

/// A015 where ownership happens: the checked file's own writes and releases of a resource field
/// another file declares (`outside`). That type is lent what its field holds (0.3's raw handle is
/// lent, `own.OwnedIo` owned) as far as its own file shows, so an owner written into it (`s.f = opened()`, a literal of it), a release
/// of it, or an owner handed by value to a function that keeps it in a resource field some file
/// releases (`keeper.keep(opened())`, unless the caller releases it itself; its parameter reads as
/// a view in the keeper) is an owner held by hand here. A keeper that does not resolve, or a field's
/// address taken, is undecided.
fn foreign(c: *Context, rule: Rule, resources: []const ?Facts.Container) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const advice = "aegis own.Owned holds an owner, and its borrow().* is what a type that lends its field is given";
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (c.inTest(tree.nodeMainToken(node)) or !Danger.atRuntime(c, node)) continue;
        if (try fieldAccess(c, tree, node)) |access| {
            const name_token = access.token;
            const receiver_value = try c.facts.resolve(c.file, access.receiver);
            const name = access.name orelse {
                // `@field` by a name it computes may be any resource field of the type.
                if (!try anyOutside(c, resources, receiver_value)) continue;
                if (try released(c, c.file, node, 0) != .no or try writeOf(c, resources, c.file, node) != .none) {
                    try c.undecided(rule, tree.tokenStart(name_token), .unresolved, "a field of another file's type named by a value, which may be a resource field written or released here");
                }
                continue;
            };
            const which = try outside(c, resources, receiver_value, name) orelse continue;
            switch (try released(c, c.file, node, 0)) {
                .yes => {
                    try c.at(rule, name_token, try c.allocator.print("'{s}', a std.{s} field of another file's type, is released here: a type is lent what it holds where its own file does not release it, so this releases another's owner; {s}", .{ name, resource_paths[which], advice }));
                    continue;
                },
                .unknown => {
                    try c.undecided(rule, tree.tokenStart(name_token), .unresolved, "a resource field of another file's type passed where nothing resolves, which may release it");
                    continue;
                },
                .no => {},
            }
            switch (try writeOf(c, resources, c.file, node)) {
                .none => continue,
                .address => {
                    try c.undecided(rule, tree.tokenStart(name_token), .unresolved, "the address of a resource field of a type outside the program, which may be written through");
                    continue;
                },
                .unknown => {
                    try c.undecided(rule, tree.tokenStart(name_token), .unresolved, "a resource field of another file's type given part of a value that is no literal, which may be an owner");
                    continue;
                },
                .owner => {},
            }
            try c.at(rule, name_token, try c.allocator.print("'{s}', a std.{s} field of another file's type, is given an owner here: a type is lent what it holds where its own file does not make it, so the owner is held by hand; {s}", .{ name, resource_paths[which], advice }));
            continue;
        }
        var init_buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullStructInit(&init_buffer, node)) |literal| {
            const made = byValue(try c.facts.literalType(c.file, node)) orelse continue;
            for (literal.ast.fields) |value| {
                const name_token = Model.initName(tree, value) orelse continue;
                const name = tree.tokenSlice(name_token);
                const which = try outside(c, resources, .{ .instance = made }, name) orelse continue;
                if (try filled(c, resources, c.file, value)) continue;
                try c.at(rule, name_token, try c.allocator.print("'{s}', a std.{s} field of another file's type, is given an owner here: a type is lent what it holds where its own file does not make it, so the owner is held by hand; {s}", .{ name, resource_paths[which], advice }));
            }
            continue;
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        const callee: ?Facts.Decl = switch (try c.facts.resolve(c.file, call.ast.fn_expr)) {
            .function => |decl| (try c.facts.origin(decl)) orelse decl,
            .unknown => null,
            else => continue,
        };
        // A method called on a value takes it first.
        var given: std.ArrayList(struct { node: Ast.Node.Index, position: usize }) = .empty;
        var skip: usize = 0;
        if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
            const receiver = tree.nodeData(call.ast.fn_expr).node_and_token[0];
            switch (try c.facts.resolve(c.file, receiver)) {
                .container => {},
                else => {
                    skip = 1;
                    try given.append(c.allocator, .{ .node = receiver, .position = 0 });
                },
            }
        }
        for (call.ast.params, 0..) |argument, position| try given.append(c.allocator, .{ .node = argument, .position = position + skip });
        for (given.items) |each| {
            const held = byValue(try c.facts.resolve(c.file, each.node)) orelse continue;
            const which = find(resources, held) orelse continue;
            if (try filled(c, resources, c.file, each.node) or try keptHere(c, each.node)) continue;
            const decl = callee orelse {
                try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(each.node)), .unresolved, "an owner handed by value to a function that does not resolve, which may keep it");
                continue;
            };
            switch (try stores(c, resources, decl, each.position, 0)) {
                .no => {},
                .unknown => try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(each.node)), .unresolved, "an owner handed by value to a function outside the program that passes it where nothing resolves, which may keep it"),
                .yes => try c.at(rule, tree.nodeMainToken(each.node), try c.allocator.print("a std.{s} owner handed by value to '{s}', which keeps it in a field it releases: the owner is held by hand there; {s}", .{ resource_paths[which], c.project.at(decl.file).model.declarations[@backingInt(decl.index)].name, advice })),
            }
        }
    }
    // A tuple's fields, named by position only, are no declarations: each is read where it is
    // written, as a field is. An enum's or a union's field written without a type parses the
    // same, and is a name.
    var buffer: [2]Ast.Node.Index = undefined;
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const container = tree.fullContainerDecl(&buffer, @fromBackingInt(@intCast(i))) orelse continue;
        if (tree.tokenTag(container.ast.main_token) != .keyword_struct) continue;
        for (container.ast.members) |node| {
            const field = tree.fullContainerField(node) orelse continue;
            if (!field.ast.tuple_like) continue;
            const first = tree.firstToken(node);
            if (c.inTest(first)) continue;
            const written = field.ast.type_expr.unwrap() orelse continue;
            const which = switch (try heldBy(c, resources, try c.facts.resolve(c.file, written), 0)) {
                .resource => |which| which,
                .other, .generic => continue,
                .unknown => {
                    try c.undecided(rule, tree.tokenStart(first), .unresolved, "a tuple's field whose type does not resolve may hold a std resource by value");
                    continue;
                },
            };
            try c.at(rule, first, try c.allocator.print("a tuple's field holds a std.{s} by value: aegis own.Owned names its one owner and checks it is released once; a borrow of it is its borrow().*, which is never released", .{resource_paths[which]}));
        }
    }
}

/// What a value holds by value of the std resources: one of them (`resource`, its index);
/// none; a type a generic's binding gives (`generic`); or a type that does not resolve. A
/// pointer borrows; an optional, an error union and an array hold what they wrap, a type built from field types (`@Struct`) what they hold; a choice of
/// types per build holds what any of them holds; a container a type function made holds what
/// its fields hold with the call's arguments (`Box(T)` inside `Outer(T)`), one declared once
/// being judged at its declaration, and aegis's own (`own.Owned`) being the answer.
const Holding = union(enum) { resource: usize, other, generic, unknown };

fn heldBy(c: *Context, resources: []const ?Facts.Container, value: Facts.Value, depth: usize) Context.Error!Holding {
    if (depth == 16) return .unknown;
    return switch (value) {
        .container, .instance => |k| blk: {
            if (find(resources, k)) |which| break :blk .{ .resource = which };
            const made = k.made_by orelse break :blk .other;
            if (try c.inLibrary(Contract.library, made.function.file)) break :blk .other;
            var found: Holding = .other;
            for (try Taint.fieldsOf(c, k)) |field| found = holdingOf(found, try heldBy(c, resources, try c.facts.memberField(k, field), depth + 1));
            break :blk found;
        },
        .optional, .error_union, .array => |inner| heldBy(c, resources, inner.*, depth + 1),
        // A type Zig builds from a list of field types holds what they do.
        .reified => |built| heldBy(c, resources, built.fields.*, depth + 1),
        .alternatives => |each| blk: {
            var found: Holding = .other;
            for (each) |one| found = holdingOf(found, try heldBy(c, resources, one, depth + 1));
            break :blk found;
        },
        .unknown => |why| if (why == .generic) .generic else .unknown,
        else => .other,
    };
}

/// What two parts together hold: a resource either holds, else a type that does not resolve,
/// else a binding's type.
fn holdingOf(a: Holding, b: Holding) Holding {
    if (a == .resource) return a;
    if (b == .resource) return b;
    if (a == .unknown or b == .unknown) return .unknown;
    if (a == .generic or b == .generic) return .generic;
    return .other;
}

/// A015 at each binding of a public generic, the consumer's among them: a container a type
/// function makes (`Box(std.Io.File)`), each of whose fields holds what its type, read with the
/// call's arguments, holds; and a value a generic function returns of a type its parameters
/// give. A private generic's fields and result are read from its callers where it is declared;
/// aegis's own are the owners and borrows this rule asks for.
fn bindings(c: *Context, rule: Rule, resources: []const ?Facts.Container, paths: []const []const u8) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&call_buffer, node) orelse continue;
        if (c.inTest(tree.nodeMainToken(node))) continue;
        const callee = (try c.facts.definition(c.file, call.ast.fn_expr)) orelse continue;
        const function = (try c.facts.origin(callee)) orelse continue;
        const record = c.project.at(function.file).model.declarations[@backingInt(function.index)];
        if (record.kind != .function or !record.public or !c.facts.hasGenericParameter(function)) continue;
        // aegis's own generics (`own.Owned`, `own.Lent`) are the answer, which holds its value.
        if (try c.inLibrary(Contract.library, function.file)) continue;
        const made = try c.facts.resolve(c.file, node);
        const written_tree = &c.project.at(function.file).file.tree;
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const proto = written_tree.fullFnProto(&proto_buffer, record.node) orelse continue;
        const result = proto.ast.return_type.unwrap() orelse continue;
        if (written_tree.nodeTag(result) == .identifier and std.mem.eql(u8, written_tree.tokenSlice(written_tree.nodeMainToken(result)), "type")) {
            // A type function's container: what each field holds with these arguments, a
            // container another type function made in it read the same way; a type that does
            // not resolve may hold one.
            try madeHolds(c, rule, resources, paths, tree.nodeMainToken(node), record.name, made, 0);
            continue;
        }
        // A generic function's result, where its declared type is a parameter's: an owner handed
        // over unless each return reads one held (`views`).
        if (try heldBy(c, resources, try c.facts.resolve(function.file, result), 0) != .generic) continue;
        switch (try heldBy(c, resources, made, 0)) {
            .resource => |which| if (!try views(c, resources, function, 0)) try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("this binding makes function '{s}' return a std.{s} by value that is no view of one held: an owner handed over; aegis own.Owned names its one owner and checks it is released once; a borrow of it is its borrow().*, which is never released", .{ record.name, paths[which] })),
            .other, .generic => {},
            .unknown => try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "what this binding makes a generic return does not resolve: it may be a std resource by value"),
        }
    }
}

/// A015 at a binding for what a type function made, `value`: each resource one of its fields
/// holds by value, through optionals, error unions, arrays, a choice of types and a type built
/// from field types, is a finding where that field's file makes it an owner (`owns`), else a
/// borrow; a container another type function made, held so, is read the same way; aegis's own
/// are the answer; a type that does not resolve is undecided, never clear.
fn madeHolds(c: *Context, rule: Rule, resources: []const ?Facts.Container, paths: []const []const u8, at: Ast.TokenIndex, maker: []const u8, value: Facts.Value, depth: usize) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    if (depth == 16) return c.undecided(rule, tree.tokenStart(at), .unresolved, "a container this binding makes nests past what is read: it may hold a std resource by value");
    switch (value) {
        .container, .instance => |container| {
            const made = container.made_by orelse return;
            if (try c.inLibrary(Contract.library, made.function.file)) return;
            for (try Taint.fieldsOf(c, container)) |field| {
                const declared = c.project.at(field.file).model.declarations[@backingInt(field.index)];
                const held = try c.facts.memberField(container, field);
                switch (try heldBy(c, resources, held, 0)) {
                    .resource => |which| {
                        // The field itself holds one, or a container made in it does.
                        if (byValue(held)) |k| if (find(resources, k) == null) {
                            try madeHolds(c, rule, resources, paths, at, maker, held, depth + 1);
                            continue;
                        };
                        const why = try owns(c, rule, resources, .{ .file = field.file, .scope = declared.scope }, field.file, declared, at) orelse continue;
                        try c.at(rule, at, try c.allocator.print("this binding makes field '{s}' of '{s}' hold a std.{s} by value {s}: aegis own.Owned names its one owner and checks it is released once; a borrow of it is its borrow().*, which is never released", .{ declared.name, maker, paths[which], why }));
                    },
                    .other, .generic => {},
                    .unknown => try c.undecided(rule, tree.tokenStart(at), .unresolved, "a field this binding makes has a type that does not resolve: it may hold a std resource by value"),
                }
            }
        },
        .optional, .error_union, .array => |inner| try madeHolds(c, rule, resources, paths, at, maker, inner.*, depth + 1),
        .reified => |built| try madeHolds(c, rule, resources, paths, at, maker, built.fields.*, depth + 1),
        .alternatives => |each| for (each) |one| try madeHolds(c, rule, resources, paths, at, maker, one, depth + 1),
        .unknown => |why| if (why != .generic) try c.undecided(rule, tree.tokenStart(at), .unresolved, "the type this binding makes does not resolve: it may hold a std resource by value"),
        else => {},
    }
}

/// The resource a field `name` of what `value` is (or points at) holds by value, where the field
/// is another file's (its own file judges it at its declaration, `owns`), and not aegis's, whose
/// types hold their owners and lends themselves; null for any other.
fn outside(c: *Context, resources: []const ?Facts.Container, value: Facts.Value, name: []const u8) Context.Error!?usize {
    const holder = byPointer(value) orelse return null;
    if (holder.file == c.file or try c.inLibrary(Contract.library, holder.file)) return null;
    const field = c.facts.member(holder, name) orelse return null;
    const record = c.project.at(field.file).model.declarations[@backingInt(field.index)];
    if (record.kind != .field) return null;
    const tree = &c.project.at(field.file).file.tree;
    const written = (tree.fullContainerField(record.node) orelse return null).ast.type_expr.unwrap() orelse return null;
    return find(resources, byValue(try c.facts.resolve(field.file, written)) orelse return null);
}

/// Whether the owner `node` names (a local made from what a call opened) is released in the
/// checked file by the caller itself, so a function given a copy is lent it.
fn keptHere(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    if (tree.nodeTag(node) != .identifier) return false;
    const id = (model.reference(node) orelse return false).declaration orelse return false;
    return try readsReleased(c, c.file, id, 0) == .yes;
}

const Stored = enum { no, yes, unknown };

/// Whether a function keeps its parameter at `position` in a resource field: an assignment of
/// it (or a capture or local made from it) to a field of a resource type, a literal naming it
/// for one, or a call that passes it on to a function that does; one that does not resolve may.
/// std's never does.
fn stores(c: *Context, resources: []const ?Facts.Container, function: Facts.Decl, position: usize, depth: u8) Context.Error!Stored {
    // std is given no owner by value: what keeps a handle (`File.Reader`, `File.Writer`) is lent
    // a copy of it.
    if (try c.facts.standard(function.file)) return .no;
    if (depth == 4) return .unknown;
    const tree = &c.project.at(function.file).file.tree;
    const model = &c.project.at(function.file).model;
    const record = model.declarations[@backingInt(function.index)];
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, record.node) orelse return .unknown;
    var params = proto.iterate(tree);
    var at: usize = 0;
    const name_token = while (params.next()) |param| : (at += 1) {
        if (at == position) break param.name_token orelse return .no;
    } else return .no;
    var result: Stored = .no;
    for (model.declarations, 0..) |decl, i| {
        if (decl.kind != .parameter or decl.token != name_token) continue;
        const id: Model.Declaration.Id = @fromBackingInt(@intCast(i));
        for (model.references) |reference| {
            if (reference.declaration != id) continue;
            switch (try kept(c, resources, function.file, reference.node, depth)) {
                .yes => return .yes,
                .unknown => result = .unknown,
                .no => {},
            }
        }
    }
    return result;
}

/// Whether what `node` in `file` holds is kept where it is read: assigned to a resource field,
/// named for one in a literal, or passed to a function that `stores` it.
fn kept(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!Stored {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const parent = model.parentOf(node) orelse return .no;
    if (tree.nodeTag(parent) == .grouped_expression or tree.nodeTag(parent) == .@"try") return kept(c, resources, file, parent, depth);
    if (tree.nodeTag(parent) == .assign) {
        const lhs, const rhs = tree.nodeData(parent).node_and_node;
        if (rhs != node or tree.nodeTag(lhs) != .field_access) return .no;
        const receiver, const name_token = tree.nodeData(lhs).node_and_token;
        const holder = byPointer(try c.facts.resolve(file, receiver)) orelse return .unknown;
        return ownedField(c, resources, holder, tree.tokenSlice(name_token));
    }
    var init_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&init_buffer, parent)) |literal| {
        for (literal.ast.fields) |value| {
            if (value != node) continue;
            const holder = byValue(try c.facts.literalType(file, parent)) orelse return .unknown;
            return ownedField(c, resources, holder, tree.tokenSlice(Model.initName(tree, value) orelse return .no));
        }
        return .no;
    }
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, parent) orelse return .no;
    const Kept = struct { resources: []const ?Facts.Container, node: Ast.Node.Index, depth: u8 };
    return eachCallee(c, file, call, Kept{ .resources = resources, .node = node, .depth = depth }, struct {
        fn by(k: Kept, cc: *Context, f: Project.FileId, cl: Ast.full.Call, callee: Facts.Decl) Context.Error!Stored {
            return keptBy(cc, k.resources, f, cl, callee, k.node, k.depth);
        }
    }.by);
}

/// `kept` where the call `call` makes is to `callee`: what it `stores`.
fn keptBy(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, call: Ast.full.Call, callee: Facts.Decl, node: Ast.Node.Index, depth: u8) Context.Error!Stored {
    const tree = &c.project.at(file).file.tree;
    var skip: usize = 0;
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        const receiver = tree.nodeData(call.ast.fn_expr).node_and_token[0];
        switch (try c.facts.resolve(file, receiver)) {
            .container => {},
            else => {
                skip = 1;
                if (receiver == node) return stores(c, resources, callee, 0, depth + 1);
            },
        }
    }
    for (call.ast.params, 0..) |argument, position| if (argument == node) return stores(c, resources, callee, position + skip, depth + 1);
    return .no;
}

/// `by` for each function `call` may make: the one it names, or each of a choice per build
/// (`.alternatives`), joined. A callee that is no declared function (a function pointer, a
/// value that does not resolve) may do anything with what it is given.
fn eachCallee(c: *Context, file: Project.FileId, call: Ast.full.Call, context: anytype, comptime by: fn (@TypeOf(context), *Context, Project.FileId, Ast.full.Call, Facts.Decl) Context.Error!Stored) Context.Error!Stored {
    switch (try c.facts.resolve(file, call.ast.fn_expr)) {
        .function => |decl| return by(context, c, file, call, (try c.facts.origin(decl)) orelse decl),
        .alternatives => |choices| {
            var result: Stored = .no;
            for (choices) |choice| {
                const decl = switch (choice) {
                    .function => |decl| decl,
                    else => return .unknown,
                };
                result = join(result, try by(context, c, file, call, (try c.facts.origin(decl)) orelse decl));
                if (result == .yes) return .yes;
            }
            return result;
        },
        else => return .unknown,
    }
}

/// Whether a field `name` of `holder` holds a resource by value that some file of the program
/// releases (`released`): a keeper's own owner, where one only read is lent what it keeps (a
/// type that keeps the directory it is given).
fn ownedField(c: *Context, resources: []const ?Facts.Container, holder: Facts.Container, name: []const u8) Context.Error!Stored {
    if (!try resourceField(c, resources, holder, name)) return .no;
    var result: Stored = .no;
    for (try fieldUses(c, name)) |use| {
        const receiver = byPointer(try c.facts.resolve(use.file, use.receiver)) orelse continue;
        if (receiver.file != holder.file or receiver.scope != holder.scope) continue;
        const answer = try released(c, use.file, use.node, 0);
        result = join(result, if (use.named) answer else if (answer == .no) .no else .unknown);
        if (result == .yes) return .yes;
    }
    return result;
}

/// Whether a field `name` of `holder` holds a resource by value.
fn resourceField(c: *Context, resources: []const ?Facts.Container, holder: Facts.Container, name: []const u8) Context.Error!bool {
    const field = c.facts.member(holder, name) orelse return false;
    const record = c.project.at(field.file).model.declarations[@backingInt(field.index)];
    if (record.kind != .field) return false;
    const tree = &c.project.at(field.file).file.tree;
    const written = (tree.fullContainerField(record.node) orelse return false).ast.type_expr.unwrap() orelse return false;
    return find(resources, byValue(try c.facts.resolve(field.file, written)) orelse return false) != null;
}

/// A read of a field where it is named, `x.name` or `@field(x, "name")`, by its node and its
/// receiver's. `named` is false for an `@field` whose name is no string literal: it may be any.
const FieldUse = struct { file: Project.FileId, node: Ast.Node.Index, receiver: Ast.Node.Index, named: bool = true };

/// The `@field` reads of the program's files, made once per run (`Facts.memo`): by the name
/// its string literal gives, and those whose name is computed.
const FieldBuiltins = struct {
    built: bool = false,
    named: std.StringHashMapUnmanaged(std.ArrayList(FieldUse)) = .empty,
    unnamed: std.ArrayList(FieldUse) = .empty,
};

/// The reads of a field `name` in the program's files (`x.name`, `@field(x, "name")`), and
/// every `@field` whose name is computed, which may be it.
fn fieldUses(c: *Context, name: []const u8) Context.Error![]const FieldUse {
    const index = try c.facts.memo(FieldBuiltins);
    if (!index.built) {
        index.built = true;
        for (c.project.sources) |*source| {
            if (!try c.facts.program(source.id)) continue;
            const tree = &source.file.tree;
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                if (tag == .field_access) continue;
                const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                const access = try fieldAccess(c, tree, node) orelse continue;
                const use: FieldUse = .{ .file = source.id, .node = node, .receiver = access.receiver, .named = access.name != null };
                const spelled = access.name orelse {
                    try index.unnamed.append(c.facts.gpa, use);
                    continue;
                };
                const entry = try index.named.getOrPut(c.facts.gpa, try c.facts.gpa.dupe(u8, spelled));
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(c.facts.gpa, use);
            }
        }
    }
    var uses: std.ArrayList(FieldUse) = .empty;
    for (try c.facts.memberUses(name)) |use| {
        try uses.append(c.allocator, .{ .file = use.file, .node = use.node, .receiver = c.project.at(use.file).file.tree.nodeData(use.node).node_and_token[0] });
    }
    if (index.named.get(name)) |list| try uses.appendSlice(c.allocator, list.items);
    try uses.appendSlice(c.allocator, index.unnamed.items);
    return uses.items;
}

/// The receiver, name and name's token of a field read: `x.name`, or `@field(x, "name")` with
/// the name its string gives (null where it is computed).
fn fieldAccess(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!?struct { receiver: Ast.Node.Index, name: ?[]const u8, token: Ast.TokenIndex } {
    switch (tree.nodeTag(node)) {
        .field_access => {
            const receiver, const token = tree.nodeData(node).node_and_token;
            return .{ .receiver = receiver, .name = tree.tokenSlice(token), .token = token };
        },
        .builtin_call_two, .builtin_call_two_comma => {
            const token = tree.nodeMainToken(node);
            if (!std.mem.eql(u8, tree.tokenSlice(token), "@field")) return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 2) return null;
            if (tree.nodeTag(args[1]) != .string_literal) return .{ .receiver = args[0], .name = null, .token = token };
            const name = std.zig.string_literal.parseAlloc(c.allocator, tree.tokenSlice(tree.nodeMainToken(args[1]))) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .receiver = args[0], .name = null, .token = token },
            };
            return .{ .receiver = args[0], .name = name, .token = token };
        },
        else => return null,
    }
}

/// Whether `value` is another file's type with a resource field (`outside`).
fn anyOutside(c: *Context, resources: []const ?Facts.Container, value: Facts.Value) Context.Error!bool {
    const holder = byPointer(value) orelse return false;
    for (c.project.at(holder.file).model.declarations) |decl| {
        if (decl.kind != .field or decl.scope != holder.scope) continue;
        if (try outside(c, resources, value, decl.name) != null) return true;
    }
    return false;
}

/// How a field read at `node` is written: given an owner (by `=`, or its place in a
/// destructure of a literal, its `handle` alike), its address taken (`&s.f`, a `|*p|` capture
/// of it, which may be written through), or given part of a value that is no literal (a
/// destructure of a call), which may hold one.
const Write = enum { none, owner, address, unknown };

fn writeOf(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, node: Ast.Node.Index) Context.Error!Write {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var target = node;
    var parent = model.parentOf(target) orelse return .none;
    if (tree.nodeTag(parent) == .address_of or pointerCapture(tree, model, parent, target)) return .address;
    if (tree.nodeTag(parent) == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(parent).node_and_token[1]), "handle")) {
        target = parent;
        parent = model.parentOf(target) orelse return .none;
    }
    switch (tree.nodeTag(parent)) {
        .assign => {
            const lhs, const rhs = tree.nodeData(parent).node_and_node;
            return if (lhs == target and !try filled(c, resources, file, rhs)) .owner else .none;
        },
        .assign_destructure => {
            const full = tree.assignDestructure(parent);
            const position = std.mem.findScalar(Ast.Node.Index, full.ast.variables, target) orelse return .none;
            var buffer: [2]Ast.Node.Index = undefined;
            const parts = if (tree.fullArrayInit(&buffer, full.ast.value_expr)) |literal| literal.ast.elements else return .unknown;
            if (position >= parts.len) return .unknown;
            return if (try filled(c, resources, file, parts[position])) .none else .owner;
        },
        else => return .none,
    }
}

/// Whether `parent` (an `if`, `while` or `for`) captures `node` by pointer (`|*p|`).
fn pointerCapture(tree: *const Ast, model: *const Model, parent: Ast.Node.Index, node: Ast.Node.Index) bool {
    for (model.declarations) |decl| {
        if (decl.kind != .capture or decl.node != parent or !captures(tree, parent, decl.token, node)) continue;
        if (decl.token > 0 and tree.tokenTag(decl.token - 1) == .asterisk) return true;
    }
    return false;
}

/// What makes a field of `holder` an owner, as the finding says it, or null for a borrow: its
/// file releases what it holds (`released`), or writes into it what is no view (`viewed`), by
/// an assignment to it or its `handle`, a literal of its container (or one whose type does not
/// resolve) naming it, or its default. Its address taken may be written through. `undefined`
/// holds nothing to own. A release through a receiver that does not resolve, or a read of it
/// passed where nothing resolves, is undecided, reported at `doubt_at` in the checked file. The
/// field is `file`'s: the checked file's own, or a type function's a binding here makes.
fn owns(c: *Context, rule: Rule, resources: []const ?Facts.Container, holder: Facts.Container, file: Project.FileId, decl: Model.Declaration, doubt_at: Ast.TokenIndex) Context.Error!?[]const u8 {
    const own = &c.project.at(file).file.tree;
    const owner = "that its file makes and writes into it";
    var doubt = false;
    if ((own.fullContainerField(decl.node) orelse return null).ast.value_expr.unwrap()) |default| {
        if (!try filled(c, resources, file, default)) return owner;
    }
    for (try fieldUses(c, decl.name)) |use| {
        if (use.file != file) continue;
        const resolved = try c.facts.resolve(use.file, use.receiver);
        if (resolved == .unknown) {
            doubt = doubt or try released(c, use.file, use.node, 0) != .no;
            continue;
        }
        const receiver = byPointer(resolved) orelse continue;
        if (receiver.file != holder.file or receiver.scope != holder.scope) continue;
        // `@field` by a name it computes may be this field: what it does to it is undecided.
        if (!use.named) {
            doubt = doubt or try released(c, use.file, use.node, 0) != .no or try writeOf(c, resources, use.file, use.node) != .none;
            continue;
        }
        switch (try released(c, use.file, use.node, 0)) {
            .yes => return "that its file releases",
            .unknown => doubt = true,
            .no => {},
        }
        switch (try writeOf(c, resources, use.file, use.node)) {
            .owner, .address => return owner,
            .unknown => doubt = true,
            .none => {},
        }
    }
    for (own.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = own.fullStructInit(&buffer, node) orelse continue;
        for (literal.ast.fields) |value| {
            if (!std.mem.eql(u8, own.tokenSlice(Model.initName(own, value) orelse continue), decl.name)) continue;
            const made = try c.facts.literalType(file, node);
            if (made != .unknown) {
                const of = byValue(made) orelse break;
                if (of.file != holder.file or of.scope != holder.scope) break;
            }
            if (!try filled(c, resources, file, value)) return owner;
        }
    }
    if (doubt) try c.undecided(rule, c.project.at(c.file).file.tree.tokenStart(doubt_at), .unresolved, "a field that may be released: read through a receiver that does not resolve, or passed where nothing resolves");
    return null;
}

/// Whether a value written into a field leaves it holding no owner: `undefined`, or a view.
fn filled(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, value: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    if (tree.nodeTag(value) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "undefined")) return true;
    return viewed(c, resources, file, value, 0, null);
}

/// Whether what `node` in `file` holds (a field read, a capture or local made from it, its
/// `handle`, its address, a function's return of it) is released where it is read: `close`,
/// `deinit`, `kill` or `wait` called on it, or passed to a function that releases that
/// parameter (`releasesParameter`). Passed where nothing resolves, or further than is followed,
/// it may be.
fn released(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!Stored {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    if (depth == 8) return .unknown;
    const next = depth + 1;
    const parent = model.parentOf(node) orelse return .no;
    switch (tree.nodeTag(parent)) {
        .unwrap_optional, .grouped_expression, .@"try", .address_of, .deref, .array_access => return released(c, file, parent, next),
        .field_access => {
            const name = tree.tokenSlice(tree.nodeData(parent).node_and_token[1]);
            if (std.mem.eql(u8, name, "handle")) return released(c, file, parent, next);
            if (!releasing(name)) return .no;
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, model.parentOf(parent) orelse return .no) orelse return .no;
            return if (call.ast.fn_expr == parent) .yes else .no;
        },
        // What a function returns of it is released where the function's caller releases it.
        .@"return" => {
            const function = enclosingFunction(model, tree, parent) orelse return .no;
            const proto = tree.nodeData(function).node_and_node[0];
            var found: ?Model.Declaration.Id = null;
            for (model.declarations, 0..) |decl, i| if (decl.kind == .function and decl.node == proto) {
                found = @fromBackingInt(@intCast(i));
            };
            const id = found orelse return .no;
            const name = model.declarations[@backingInt(id)].name;
            var result: Stored = .no;
            for (try c.facts.memberUses(name)) |use| {
                const callee = try c.facts.resolve(use.file, use.node);
                if (callee != .function or callee.function.file != file or callee.function.index != id) continue;
                result = join(result, try releasedCall(c, use.file, use.node, next));
                if (result == .yes) return .yes;
            }
            for (model.references) |reference| {
                if (reference.declaration != id) continue;
                result = join(result, try releasedCall(c, file, reference.node, next));
                if (result == .yes) return .yes;
            }
            return result;
        },
        else => {},
    }
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&buffer, parent)) |call| {
        for (call.ast.params, 0..) |argument, i| if (argument == node) return releasesParameter(c, file, call, i, next);
        return .no;
    }
    // A copy put in a literal, by each read of the field it names (`literalReleased`); a
    // tuple's or an array's element may be.
    var init_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&init_buffer, parent)) |literal| {
        for (literal.ast.fields) |value| if (value == node) {
            return literalReleased(c, file, parent, tree.tokenSlice(Model.initName(tree, value) orelse return .unknown), next);
        };
        return .no;
    }
    if (tree.fullArrayInit(&init_buffer, parent)) |literal| {
        for (literal.ast.elements) |element| if (element == node) return .unknown;
        return .no;
    }
    // A local made from it, or a capture of it, by each read of it.
    for (model.declarations, 0..) |decl, i| {
        const binds = switch (decl.kind) {
            .variable => if (tree.fullVarDecl(decl.node)) |variable| decl.node == parent and variable.ast.init_node.unwrap() == node else false,
            .capture => decl.node == parent and captures(tree, parent, decl.token, node),
            else => false,
        };
        if (!binds) continue;
        return readsReleased(c, file, @fromBackingInt(@intCast(i)), next);
    }
    return .no;
}

/// Whether the field `name` of a struct literal is `released`: the literal a local's value, by
/// each read of that field of it. The local read whole (passed, copied, its address taken) or a
/// method called on it, or the literal not a local's value, may release it.
fn literalReleased(c: *Context, file: Project.FileId, literal: Ast.Node.Index, name: []const u8, depth: u8) Context.Error!Stored {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    if (depth == 8) return .unknown;
    const parent = model.parentOf(literal) orelse return .unknown;
    const id = for (model.declarations, 0..) |decl, i| {
        if (decl.kind != .variable or decl.node != parent) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        if (variable.ast.init_node.unwrap() == literal) break @as(Model.Declaration.Id, @fromBackingInt(@intCast(i)));
    } else return .unknown;
    var result: Stored = .no;
    for (model.references) |reference| {
        if (reference.declaration != id) continue;
        const read = model.parentOf(reference.node) orelse return .unknown;
        if (tree.nodeTag(read) != .field_access or tree.nodeData(read).node_and_token[0] != reference.node) return .unknown;
        if (std.mem.eql(u8, tree.tokenSlice(tree.nodeData(read).node_and_token[1]), name)) {
            result = join(result, try released(c, file, read, depth + 1));
            if (result == .yes) return .yes;
            continue;
        }
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, model.parentOf(read) orelse continue)) |call| if (call.ast.fn_expr == read) return .unknown;
    }
    return result;
}

/// Whether some read of the declaration `id` in `file` is `released`.
fn readsReleased(c: *Context, file: Project.FileId, id: Model.Declaration.Id, depth: u8) Context.Error!Stored {
    var result: Stored = .no;
    for (c.project.at(file).model.references) |reference| {
        if (reference.declaration != id) continue;
        result = join(result, try released(c, file, reference.node, depth));
        if (result == .yes) return .yes;
    }
    return result;
}

/// The weaker of two answers that something is so: so where either is, else undecided where
/// either is.
fn join(a: Stored, b: Stored) Stored {
    if (a == .yes or b == .yes) return .yes;
    if (a == .unknown or b == .unknown) return .unknown;
    return .no;
}

/// Whether the call `callee` (a name or member access) makes is released where it is read.
fn releasedCall(c: *Context, file: Project.FileId, callee: Ast.Node.Index, depth: u8) Context.Error!Stored {
    const tree = &c.project.at(file).file.tree;
    const parent = c.project.at(file).model.parentOf(callee) orelse return .no;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, parent) orelse return .no;
    if (call.ast.fn_expr != callee) return .no;
    return released(c, file, parent, depth);
}

/// Whether the capture declared at `token` of `parent` (an `if`, `while` or `for`) binds `node`:
/// the condition's payload, or the item of the input `node` is.
fn captures(tree: *const Ast, parent: Ast.Node.Index, token: Ast.TokenIndex, node: Ast.Node.Index) bool {
    if (tree.fullIf(parent)) |branch| return branch.ast.cond_expr == node and branch.payload_token != null and branch.error_token != token;
    if (tree.fullWhile(parent)) |loop| return loop.ast.cond_expr == node and loop.payload_token != null and loop.error_token != token;
    if (tree.fullFor(parent)) |loop| {
        const position = Model.capturePosition(tree, loop, token) orelse return false;
        return position < loop.ast.inputs.len and loop.ast.inputs[position] == node;
    }
    return false;
}

fn releasing(name: []const u8) bool {
    for ([_][]const u8{ "close", "deinit", "kill", "wait" }) |each| if (std.mem.eql(u8, name, each)) return true;
    return false;
}

/// Whether a call releases its argument at `position`: a program function by a release of that
/// parameter in its body (`released`), std's by its name (`close`, `deinit`, `kill`, `wait`), a
/// choice per build by each (`eachCallee`), and one that is no declared function (a function
/// pointer, a value that does not resolve) may.
fn releasesParameter(c: *Context, file: Project.FileId, call: Ast.full.Call, position: usize, depth: u8) Context.Error!Stored {
    const At = struct { position: usize, depth: u8 };
    return eachCallee(c, file, call, At{ .position = position, .depth = depth }, struct {
        fn by(at: At, cc: *Context, f: Project.FileId, cl: Ast.full.Call, callee: Facts.Decl) Context.Error!Stored {
            return releasesBy(cc, f, cl, callee, at.position, at.depth);
        }
    }.by);
}

/// `releasesParameter` where the call is to `callee`.
fn releasesBy(c: *Context, file: Project.FileId, call: Ast.full.Call, callee: Facts.Decl, position: usize, depth: u8) Context.Error!Stored {
    const tree = &c.project.at(file).file.tree;
    const target = &c.project.at(callee.file).file.tree;
    const target_model = &c.project.at(callee.file).model;
    const record = target_model.declarations[@backingInt(callee.index)];
    if (!try c.facts.program(callee.file)) return if (releasing(record.name)) .yes else .no;
    // A method called on a value takes it as its first parameter.
    var skip: usize = 0;
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) switch (try c.facts.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
        .container => {},
        else => skip = 1,
    };
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = target.fullFnProto(&proto_buffer, record.node) orelse return .unknown;
    var params = proto.iterate(target);
    var at: usize = 0;
    const name_token = while (params.next()) |param| : (at += 1) {
        if (at == position + skip) break param.name_token orelse return .no;
    } else return .no;
    for (target_model.declarations, 0..) |decl, i| {
        if (decl.kind != .parameter or decl.token != name_token) continue;
        return readsReleased(c, callee.file, @fromBackingInt(@intCast(i)), depth);
    }
    return .no;
}

/// Whether `node` in `file` is an argument of a call that does not release it (`released`): a
/// copy of a std handle that call is lent.
pub fn lentArgument(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const parent = c.project.at(file).model.parentOf(node) orelse return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, parent) orelse return false;
    for (call.ast.params) |argument| if (argument == node) return try released(c, file, node, 0) == .no;
    return false;
}

/// Whether `node`, a call, acquires a std resource (`resource_paths`) by value: one it is not
/// lent (`viewed`), as `dir.openFile` gives, for A003 to follow to its release.
pub fn acquiresHandle(c: *Context, rule: Rule, node: Ast.Node.Index) Context.Error!bool {
    const held = byValue(try c.facts.resolve(c.file, node)) orelse returned: {
        // What std's own bodies give may not resolve: the callee's declared result does.
        const tree = &c.project.at(c.file).file.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse return false;
        const callee = switch (try c.facts.resolve(c.file, call.ast.fn_expr)) {
            .function => |decl| (try c.facts.origin(decl)) orelse decl,
            else => return false,
        };
        const target = &c.project.at(callee.file).file.tree;
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const proto = target.fullFnProto(&proto_buffer, c.project.at(callee.file).model.declarations[@backingInt(callee.index)].node) orelse return false;
        const written = proto.ast.return_type.unwrap() orelse return false;
        break :returned byValue(try c.facts.resolve(callee.file, written)) orelse return false;
    };
    const resources = try containersOf(c, rule, &resource_paths);
    if (find(resources, held) == null) return false;
    return !try viewed(c, resources, c.file, node, 0, null);
}

/// A call of the program's function whose returns `views` reads: there a parameter of the
/// callee is the argument the call passes at it, read where the call is (`outer` the binding in
/// force there).
const Binding = struct { file: Project.FileId, call: Ast.full.Call, callee: Facts.Decl, outer: ?*const Binding };

/// Whether the parameter `record` of `file` is a view: in its own function, read with no call
/// binding it, it is lent; bound, it is the argument passed at it (a method's receiver first). A
/// parameter of another function, or one the call passes nothing at, is no view.
fn argumentViewed(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, record: Model.Declaration, depth: u8, bound: ?*const Binding) Context.Error!bool {
    const binding = bound orelse return true;
    if (binding.callee.file != file) return false;
    const tree = &c.project.at(file).file.tree;
    const callee = c.project.at(file).model.declarations[@backingInt(binding.callee.index)];
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, callee.node) orelse return false;
    var params = proto.iterate(tree);
    var position: usize = 0;
    while (params.next()) |param| : (position += 1) {
        if (param.name_token == record.token) break;
    } else return false;
    const caller = &c.project.at(binding.file).file.tree;
    const call = binding.call;
    if (caller.nodeTag(call.ast.fn_expr) == .field_access) {
        const receiver = caller.nodeData(call.ast.fn_expr).node_and_token[0];
        switch (try c.facts.resolve(binding.file, receiver)) {
            .container => {},
            else => {
                if (position == 0) return viewed(c, resources, binding.file, receiver, depth, binding.outer);
                position -= 1;
            },
        }
    }
    if (position >= call.ast.params.len) return false;
    return viewed(c, resources, binding.file, call.ast.params[position], depth, binding.outer);
}

/// Whether every return of a function reads a resource someone already holds, so it hands over
/// no owner: a parameter passed back, a field read (the field's declaration is where its owner is
/// judged) of something itself held, a declared constant, std's process-wide `stdin`, `stdout` or
/// `stderr`, which nobody closes, a literal naming a handle it was given (`.{ .handle = handle
/// }`), an `own.Owned`'s `borrow().*`, or a call of the program's function that is itself one. A
/// variable (a field moved out first) or what any other call made is an owner handed over.
fn views(c: *Context, resources: []const ?Facts.Container, function: Facts.Decl, depth: u8, bound: ?*const Binding) Context.Error!bool {
    const tree = &c.project.at(function.file).file.tree;
    const model = &c.project.at(function.file).model;
    const decl = model.declarations[@backingInt(function.index)];
    const body = body: {
        const parent = model.parentOf(decl.node) orelse return false;
        if (tree.nodeTag(parent) != .fn_decl) return false;
        break :body tree.nodeData(parent).node_and_node[1];
    };
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    var returns: usize = 0;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        const value = tree.nodeData(node).opt_node.unwrap() orelse return false;
        if (!try viewed(c, resources, function.file, value, depth, bound)) return false;
        returns += 1;
    }
    return returns != 0;
}

/// Whether a function is one std's `Io` calls through its vtable: it takes the `?*anyopaque`
/// userdata first and is named, not called, as a literal's value for a field `Io.VTable`
/// declares (`.processSpawn = seam.routedSpawn`). The vtable fixes its signature, and the
/// caller of the `Io` operation owns what it returns, as with std's own implementations.
fn implements(c: *Context, index: Model.Declaration.Id, maybe_vtable: ?Facts.Container) Context.Error!bool {
    const vtable = maybe_vtable orelse return false;
    const decl = c.project.at(c.file).model.declarations[@backingInt(index)];
    const own = &c.project.at(c.file).file.tree;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = own.fullFnProto(&proto_buffer, decl.node) orelse return false;
    var params = proto.iterate(own);
    const first = params.next() orelse return false;
    if (!std.mem.eql(u8, own.getNodeSource(first.type_expr orelse return false), "?*anyopaque")) return false;
    for (c.project.sources) |*source| {
        if (!try Program.owns(c, source.id)) continue;
        const file = source.id;
        const tree = &source.file.tree;
        for (tree.nodes.items(.tag), 0..) |_, i| {
            var buffer: [2]Ast.Node.Index = undefined;
            const literal = tree.fullStructInit(&buffer, @fromBackingInt(@intCast(i))) orelse continue;
            for (literal.ast.fields) |value| {
                var named = value;
                if (tree.nodeTag(named) == .address_of) named = tree.nodeData(named).node;
                if (!std.mem.eql(u8, tree.tokenSlice(tree.lastToken(named)), decl.name)) continue;
                if (tree.firstToken(value) < 2) continue;
                const slot = c.facts.member(vtable, tree.tokenSlice(Model.initName(tree, value) orelse continue)) orelse continue;
                if (c.project.at(slot.file).model.declarations[@backingInt(slot.index)].kind != .field) continue;
                switch (try c.facts.resolve(file, named)) {
                    .function => |d| if (d.file == c.file and d.index == index) return true,
                    else => {},
                }
            }
        }
    }
    return false;
}

fn viewed(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, node: Ast.Node.Index, depth: u8, bound: ?*const Binding) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    if (depth == 16) return false;
    const next = depth + 1;
    switch (tree.nodeTag(node)) {
        .grouped_expression => return viewed(c, resources, file, tree.nodeData(node).node_and_token[0], next, bound),
        .unwrap_optional => return viewed(c, resources, file, tree.nodeData(node).node_and_token[0], next, bound),
        .array_access => return viewed(c, resources, file, tree.nodeData(node).node_and_node[0], next, bound),
        .@"orelse" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return try viewed(c, resources, file, lhs, next, bound) and try viewed(c, resources, file, rhs, next, bound);
        },
        .field_access => {
            var root = node;
            while (tree.nodeTag(root) == .field_access or tree.nodeTag(root) == .unwrap_optional or tree.nodeTag(root) == .array_access) root = switch (tree.nodeTag(root)) {
                .array_access => tree.nodeData(root).node_and_node[0],
                else => tree.nodeData(root).node_and_token[0],
            };
            return tree.nodeTag(root) == .identifier and try viewed(c, resources, file, root, next, bound);
        },
        // No value: a prong that never returns, or one that leaves (`orelse return null`).
        .unreachable_literal, .@"return", .@"continue" => return true,
        // An `own.Owned`'s `borrow().*`: the owner keeps what it lends. Any other `p.*` reads
        // what `p` points at, a view where `p` is one.
        .deref => {
            const pointer = tree.nodeData(node).node;
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, pointer) orelse return viewed(c, resources, file, pointer, next, bound);
            if (call.ast.params.len != 0 or tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
            const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(method), "borrow")) return false;
            return try c.role(Contract.library, try c.facts.resolve(file, receiver)) == .owned;
        },
        .identifier => {
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "null")) return true;
            const reference = model.reference(node) orelse return false;
            const d = reference.declaration orelse return false;
            const record = model.declarations[@backingInt(d)];
            // A parameter is a view in its own function; read through a call (`Binding`), it is
            // what that call passes.
            if (record.kind == .parameter) return argumentViewed(c, resources, file, record, next, bound);
            // A capture holds what it binds: a view where that is one (an owner a call made,
            // unwrapped, is handed over).
            if (record.kind == .capture) {
                const captured: ?Ast.Node.Index = if (tree.fullIf(record.node)) |branch| branch.ast.cond_expr else if (tree.fullWhile(record.node)) |loop| loop.ast.cond_expr else if (tree.fullFor(record.node)) |loop| (if (loop.ast.inputs.len == 1) loop.ast.inputs[0] else null) else if (tree.fullSwitchCase(record.node) != null) (if (tree.fullSwitch(model.parentOf(record.node) orelse return false)) |full| full.ast.condition else null) else null;
                return viewed(c, resources, file, captured orelse return false, next, bound);
            }
            if (record.kind != .variable) return false;
            const variable = tree.fullVarDecl(record.node) orelse return false;
            if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
            // A declared constant, or a local one made from what is already held.
            return switch (model.scopes[@backingInt(record.scope)].kind) {
                .file, .container => true,
                else => try viewed(c, resources, file, variable.ast.init_node.unwrap() orelse return false, next, bound),
            };
        },
        .@"switch", .switch_comma => {
            const full = tree.fullSwitch(node).?;
            for (full.ast.cases) |case| if (!try viewed(c, resources, file, tree.fullSwitchCase(case).?.ast.target_expr, next, bound)) return false;
            return true;
        },
        else => {
            if (tree.fullIf(node)) |branch| {
                const otherwise = branch.ast.else_expr.unwrap() orelse return false;
                return try viewed(c, resources, file, branch.ast.then_expr, next, bound) and try viewed(c, resources, file, otherwise, next, bound);
            }
            var buffer: [1]Ast.Node.Index = undefined;
            if (tree.fullCall(&buffer, node)) |call| {
                // An `own.Lent`'s `get()`: a copy its owner lends.
                if (call.ast.params.len == 0 and tree.nodeTag(call.ast.fn_expr) == .field_access) {
                    const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
                    if (std.mem.eql(u8, tree.tokenSlice(method), "get") and try c.role(Contract.library, try c.facts.resolve(file, receiver)) == .lent) return true;
                }
                const callee = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
                    .function => |decl| (try c.facts.origin(decl)) orelse decl,
                    else => return false,
                };
                // The program's function whose every return is a view returns one.
                if (try c.facts.program(callee.file)) return views(c, resources, callee, next, &.{ .file = file, .call = call, .callee = callee, .outer = bound });
                if (call.ast.params.len != 0) return false;
                for ([_][]const u8{ "Io.File.stdin", "Io.File.stdout", "Io.File.stderr", "Io.Dir.cwd" }) |standard| {
                    for ((try Governed.declarations(c, "std", standard)) orelse &.{}) |decl| {
                        if (std.meta.eql((try c.facts.origin(decl)) orelse decl, callee)) return true;
                    }
                }
                return false;
            }
            var init_buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullStructInit(&init_buffer, node)) |literal| {
                // A std handle made from one it is given: the literal of a std resource type.
                const made = byValue(try c.facts.literalType(file, node)) orelse return false;
                if (find(resources, made) == null) return false;
                for (literal.ast.fields) |value| {
                    if (!std.mem.eql(u8, tree.tokenSlice(Model.initName(tree, value) orelse continue), "handle")) continue;
                    return viewed(c, resources, file, value, next, bound);
                }
                return false;
            }
            return false;
        },
    }
}

/// A021: lock order. A function that holds a guard of an aegis owner (`Guarded`,
/// `BlockingGuarded`, `RwGuarded`, `SpinRwGuarded`, `Order.Ordered`) while it acquires another:
/// two tasks that take two locks in two orders deadlock. The site is the second acquisition,
/// unless both are ranked (`acquireOrdered`, `readOrdered`, `writeOrdered`, their forms), which
/// `Order` checks in Debug. A guard is held from its acquisition to a `deinit` or `release` of it
/// that is a statement of its own block (one under a branch may not run), or to the block's end
/// when that is deferred, or when the guard is bound by no declaration of its own. An acquisition
/// on a receiver that does not resolve is undecided in a function that takes a guard. One
/// function's own acquisitions only: a call made while holding a guard is not followed.
pub fn lockOrder(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const Held = struct { first: Ast.TokenIndex, last: Ast.TokenIndex, ranked: bool };
    var held: std.ArrayList(Held) = .empty;
    var acquisitions: std.ArrayList(struct { node: Ast.Node.Index, ranked: bool }) = .empty;
    var unresolved: std.ArrayList(struct { node: Ast.Node.Index, why: Facts.Unknown }) = .empty;
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
        const receiver, const method_token = tree.nodeData(call.ast.fn_expr).node_and_token;
        const method = tree.tokenSlice(method_token);
        var acquires = false;
        for ([_][]const u8{ "acquire", "read", "write", "tryAcquire", "tryRead", "tryWrite" }) |prefix| acquires = acquires or std.mem.startsWith(u8, method, prefix);
        if (!acquires or c.inTest(tree.nodeMainToken(node)) or !Danger.atRuntime(c, node)) continue;
        const owner = try c.facts.resolve(c.file, receiver);
        if (owner == .unknown) {
            try unresolved.append(c.allocator, .{ .node = node, .why = owner.unknown });
            continue;
        }
        if (try c.role(Contract.library, owner) != .guarded) continue;
        const ranked = std.mem.find(u8, method, "Ordered") != null;
        try acquisitions.append(c.allocator, .{ .node = node, .ranked = ranked });
        // The guard's local, and how long it is held.
        const parent = model.parentOf(node) orelse continue;
        var at = parent;
        while (tree.nodeTag(at) == .@"try" or tree.nodeTag(at) == .@"catch" or tree.nodeTag(at) == .grouped_expression) at = model.parentOf(at) orelse break;
        const block = enclosingBlock(tree, model, at) orelse continue;
        const variable = tree.fullVarDecl(at) orelse {
            try held.append(c.allocator, .{ .first = tree.lastToken(node), .last = tree.lastToken(block), .ranked = ranked });
            continue;
        };
        const name = tree.tokenSlice(variable.ast.mut_token + 1);
        const end = releaseOf(tree, block, at, name);
        try held.append(c.allocator, .{ .first = tree.lastToken(at), .last = end, .ranked = ranked });
    }
    // What does not resolve may be a guard where the function takes one.
    for (unresolved.items) |each| for (acquisitions.items) |known| {
        if (enclosingFunction(model, tree, known.node) != enclosingFunction(model, tree, each.node)) continue;
        try c.unknown(rule, each.node, each.why);
        break;
    };
    for (acquisitions.items) |second| {
        const token = tree.nodeMainToken(second.node);
        for (held.items) |first| {
            if (token <= first.first or token > first.last) continue;
            if (first.ranked and second.ranked) continue;
            try c.at(rule, tree.firstToken(second.node), "a second lock taken while a guard is held, not both ranked: two tasks taking them in two orders deadlock; aegis Order ranks them and checks the order in Debug");
            break;
        }
    }
}

/// The block a statement stands in.
fn enclosingBlock(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Ast.Node.Index {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => return parent,
            .fn_decl => return null,
            else => {},
        }
    }
    return null;
}

/// Where a guard named `name`, declared by the statement `declared` of `block`, is released: the
/// first later statement of the block that is its `deinit(` or `release(` call, or the block's
/// end (a deferred release runs there, and one under a branch may not run at all).
fn releaseOf(tree: *const Ast, block: Ast.Node.Index, declared: Ast.Node.Index, name: []const u8) Ast.TokenIndex {
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block) orelse return tree.lastToken(block);
    const start = std.mem.findScalar(Ast.Node.Index, statements, declared) orelse return tree.lastToken(block);
    for (statements[start + 1 ..]) |statement| {
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&call_buffer, statement) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
        const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (tree.nodeTag(receiver) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(receiver)), name)) continue;
        const spelled = tree.tokenSlice(method);
        if (std.mem.eql(u8, spelled, "deinit") or std.mem.eql(u8, spelled, "release")) return tree.firstToken(statement);
    }
    return tree.lastToken(block);
}

/// A016: two or more identifying integers of one type meeting in one public signature or one
/// public struct, where nothing keeps one from standing for the other.
pub fn identity(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations) |decl| {
        if (decl.kind != .function or !decl.public or c.inTest(decl.token)) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, decl.node) orelse continue;
        var names: std.ArrayList(Ast.TokenIndex) = .empty;
        var types: std.ArrayList([]const u8) = .empty;
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            const name = param.name_token orelse continue;
            if (param.comptime_noalias != null or !identifies(tree.tokenSlice(name))) continue;
            const kind = integer(try c.facts.resolve(c.file, param.type_expr orelse continue)) orelse continue;
            try names.append(c.allocator, name);
            try types.append(c.allocator, kind);
        }
        if (try meet(c, tree, names.items, types.items)) |pair| try c.at(rule, decl.token, try c.allocator.print("'{s}' and '{s}' are both {s} that identify: one may be passed for the other; aegis id.Id or a handle gives each its own type", .{ tree.tokenSlice(pair[0]), tree.tokenSlice(pair[1]), pair[2] }));
    }
    for (model.scopes) |scope| {
        if (scope.kind != .container and scope.kind != .file) continue;
        if (scope.kind == .container and !publicContainer(tree, model, scope.node)) continue;
        var names: std.ArrayList(Ast.TokenIndex) = .empty;
        var types: std.ArrayList([]const u8) = .empty;
        for (model.declarations) |decl| {
            if (decl.kind != .field or decl.scope != scope.id or c.inTest(decl.token) or !identifies(decl.name)) continue;
            const written = (tree.fullContainerField(decl.node) orelse continue).ast.type_expr.unwrap() orelse continue;
            const kind = integer(try c.facts.resolve(c.file, written)) orelse continue;
            try names.append(c.allocator, decl.token);
            try types.append(c.allocator, kind);
        }
        if (try meet(c, tree, names.items, types.items)) |pair| try c.at(rule, pair[1], try c.allocator.print("fields '{s}' and '{s}' are both {s} that identify: one may be stored for the other; aegis id.Id or a handle gives each its own type", .{ tree.tokenSlice(pair[0]), tree.tokenSlice(pair[1]), pair[2] }));
    }
}

/// The first two names of one integer type, and that type.
fn meet(c: *Context, tree: *const Ast, names: []const Ast.TokenIndex, types: []const []const u8) Context.Error!?struct { Ast.TokenIndex, Ast.TokenIndex, []const u8 } {
    _ = c;
    _ = tree;
    for (types, 0..) |kind, i| for (types[0..i], 0..) |earlier, j| {
        if (std.mem.eql(u8, kind, earlier)) return .{ names[j], names[i], kind };
    };
    return null;
}

/// Whether a name says what it holds identifies something: `id`, `index` or `handle`, alone or
/// as the last word (`node_id`, `nodeIndex`).
fn identifies(name: []const u8) bool {
    for ([_][]const u8{ "id", "index", "handle", "idx" }) |word| {
        if (std.ascii.eqlIgnoreCase(name, word)) return true;
        if (name.len <= word.len) continue;
        const head = name[0 .. name.len - word.len];
        const tail = name[name.len - word.len ..];
        if (head.len == 0) continue;
        const before = head[head.len - 1];
        if (before == '_' and std.mem.eql(u8, tail, word)) return true;
        // camelCase: the word starts upper case after a lower-case letter or digit.
        if (std.ascii.isUpper(tail[0]) and std.ascii.eqlIgnoreCase(tail, word) and std.mem.eql(u8, tail[1..], word[1..]) and (std.ascii.isLower(before) or std.ascii.isDigit(before))) return true;
    }
    return false;
}

/// The integer type a resolved value names, by its spelling in Zig (`u32`, `usize`).
fn integer(value: Facts.Value) ?[]const u8 {
    const name = switch (value) {
        .primitive => |name| name,
        else => return null,
    };
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return name;
    if (name.len < 2 or (name[0] != 'u' and name[0] != 'i')) return null;
    for (name[1..]) |byte| if (!std.ascii.isDigit(byte)) return null;
    return name;
}

/// Whether a container is declared `pub` (`pub const S = struct { ... }`).
fn publicContainer(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    const parent = model.parentOf(node) orelse return true;
    const variable = tree.fullVarDecl(parent) orelse return false;
    return variable.visib_token != null;
}

/// A017: an enum state written by two or more functions, switched on, and moved on its own value:
/// a state machine kept by hand, where nothing says which transitions are allowed. A move is a
/// write under a switch or a condition on the field (`switch (f.state) { .start => f.state =
/// .value, ... }`), there or where the function that writes it is called. A kind set where its
/// value is built or read (a table's layout, a date's kind) is data. A field moved on the records
/// a loop walks is moved on each of them: a record's states kept by hand all the same.
pub fn stateMachines(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations) |decl| {
        if (decl.kind != .field or c.inTest(decl.token)) continue;
        const written = (tree.fullContainerField(decl.node) orelse continue).ast.type_expr.unwrap() orelse continue;
        const state = byValue(try c.facts.resolve(c.file, written)) orelse continue;
        if (!isEnum(c, state)) continue;
        const holder: Facts.Container = .{ .file = c.file, .scope = decl.scope };
        var uses: std.ArrayList(Facts.Key) = .empty;
        var writes: std.ArrayList(Facts.Key) = .empty;
        var writers: std.ArrayList(Facts.Key) = .empty;
        var switched = false;
        for (try c.facts.memberUses(decl.name)) |use| {
            const use_tree = &c.project.at(use.file).file.tree;
            const use_model = &c.project.at(use.file).model;
            const receiver = try c.facts.resolve(use.file, use_tree.nodeData(use.node).node_and_token[0]);
            const owner = byPointer(receiver) orelse continue;
            if (owner.file != holder.file or owner.scope != holder.scope) continue;
            try uses.append(c.allocator, use);
            const parent = use_model.parentOf(use.node) orelse continue;
            if (use_tree.nodeTag(parent) == .assign and use_tree.nodeData(parent).node_and_node[0] == use.node) {
                try writes.append(c.allocator, .{ .file = use.file, .node = parent });
                const function = enclosingFunction(use_model, use_tree, parent) orelse continue;
                for (writers.items) |seen| {
                    if (seen.file == use.file and seen.node == function) break;
                } else try writers.append(c.allocator, .{ .file = use.file, .node = function });
            }
            if (use_tree.fullSwitch(parent)) |s| switched = switched or s.ast.condition == use.node;
        }
        if (writers.items.len < 2 or !switched or !try moved(c, uses.items, writes.items)) continue;
        try c.at(rule, decl.token, try c.allocator.print("'{s}' is a state machine kept by hand: written in {d} functions, moved on its own value and switched on; aegis state.Machine states which transitions there are", .{ decl.name, writers.items.len }));
    }
}

/// Whether one of `writes` is a move: under a switch or a condition on the field (one of `uses`),
/// or in a function a call under one makes.
fn moved(c: *Context, uses: []const Facts.Key, writes: []const Facts.Key) Context.Error!bool {
    for (writes) |write| {
        const tree = &c.project.at(write.file).file.tree;
        const model = &c.project.at(write.file).model;
        const function = enclosingFunction(model, tree, write.node) orelse continue;
        if (conditioned(tree, model, uses, write.file, write.node, function)) return true;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, function) orelse continue;
        const name = tree.tokenSlice(proto.name_token orelse continue);
        for (try c.facts.memberUses(name)) |call| {
            const callee = try c.facts.resolve(call.file, call.node);
            if (callee != .function or callee.function.file != write.file) continue;
            if (model.declarations[@backingInt(callee.function.index)].node != tree.nodeData(function).node_and_node[0]) continue;
            const call_tree = &c.project.at(call.file).file.tree;
            const call_model = &c.project.at(call.file).model;
            const caller = enclosingFunction(call_model, call_tree, call.node) orelse continue;
            if (conditioned(call_tree, call_model, uses, call.file, call.node, caller)) return true;
        }
    }
    return false;
}

/// Whether `node` sits in a branch a switch or an `if`/`while` on one of `uses` selects, within
/// `function`.
fn conditioned(tree: *const Ast, model: *const Model, uses: []const Facts.Key, file: Project.FileId, node: Ast.Node.Index, function: Ast.Node.Index) bool {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (parent == function) return false;
        const condition = if (tree.fullSwitch(parent)) |s|
            s.ast.condition
        else if (tree.fullIf(parent)) |branch|
            branch.ast.cond_expr
        else if (tree.fullWhile(parent)) |loop|
            loop.ast.cond_expr
        else
            continue;
        if (condition == at) continue;
        const first = tree.firstToken(condition);
        const last = tree.lastToken(condition);
        for (uses) |use| {
            if (use.file != file) continue;
            const token = tree.nodeMainToken(use.node);
            if (token >= first and token <= last) return true;
        }
    }
    return false;
}

fn isEnum(c: *Context, value: Facts.Container) bool {
    const tree = &c.project.at(value.file).file.tree;
    const node = c.project.at(value.file).model.scopes[@backingInt(value.scope)].node;
    if (node == .root) return false;
    return tree.tokenTag(tree.nodeMainToken(node)) == .keyword_enum;
}

fn enclosingFunction(model: *const Model, tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) return parent;
    }
    return null;
}

/// A014: a borrow of a std container's storage (its `items`, a part or an element's address, a
/// `getPtr`, `getEntry`, `getKeyPtr`, `keys` or `values`) stored into a field, where it
/// outlives the next growth that moves the storage.
pub fn borrowsStored(c: *Context, rule: Rule) Context.Error!void {
    const paths = [_][]const u8{ "array_list", "hash_map", "array_hash_map" };
    const namespaces = try containersOf(c, rule, &paths);
    if (namespaces.len == 0) return;
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .assign) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const target, const value = tree.nodeData(node).node_and_node;
        if (tree.nodeTag(target) != .field_access or c.inTest(tree.nodeMainToken(node)) or !Danger.atRuntime(c, node)) continue;
        const what = (try borrow(c, tree, namespaces, value)) orelse continue;
        if (try settled(c, node, value)) continue;
        try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("a borrow of a std container's storage ({s}) stored in a field: the next growth moves it; aegis handle keys or scope references stay valid", .{what}));
    }
}

/// What borrow of std container storage `node` is, if it is one.
fn borrow(c: *Context, tree: *const Ast, namespaces: []const ?Facts.Container, node: Ast.Node.Index) Context.Error!?[]const u8 {
    switch (tree.nodeTag(node)) {
        .grouped_expression => return borrow(c, tree, namespaces, tree.nodeData(node).node_and_token[0]),
        .unwrap_optional => return borrow(c, tree, namespaces, tree.nodeData(node).node_and_token[0]),
        .address_of => {
            const inner = tree.nodeData(node).node;
            if (tree.nodeTag(inner) != .array_access) return null;
            return borrow(c, tree, namespaces, tree.nodeData(inner).node_and_node[0]);
        },
        .slice_open, .slice, .slice_sentinel => return borrow(c, tree, namespaces, (tree.fullSlice(node) orelse return null).ast.sliced),
        .field_access => {
            const receiver, const name = tree.nodeData(node).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(name), "items")) return null;
            return if (try ofStd(c, namespaces, receiver)) "items" else null;
        },
        else => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, node) orelse return null;
            if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
            const receiver, const name = tree.nodeData(call.ast.fn_expr).node_and_token;
            const spelled = tree.tokenSlice(name);
            for ([_][]const u8{ "getPtr", "getEntry", "getKeyPtr", "keys", "values" }) |method| if (std.mem.eql(u8, spelled, method)) {
                return if (try ofStd(c, namespaces, receiver)) method else null;
            };
            return null;
        },
    }
}

/// Whether the borrowed container is a local nothing grows once the store is made: declared
/// in the function by value (no pointer to one held elsewhere), each of its mentions a member
/// of it (`held.append(`, `held.items`, never `&held` or `held` handed on, so no alias grows
/// it), none after the store, and the store in no loop inside the local's scope that a next
/// pass could grow it in. Once the function returns the list is gone, and with it every way to
/// move its storage (parley's agreed task ids, collected into an arena list).
fn settled(c: *Context, store: Ast.Node.Index, value: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var at = value;
    while (true) at = switch (tree.nodeTag(at)) {
        .grouped_expression, .unwrap_optional => tree.nodeData(at).node_and_token[0],
        .address_of => tree.nodeData(at).node,
        .array_access => tree.nodeData(at).node_and_node[0],
        .slice_open, .slice, .slice_sentinel => (tree.fullSlice(at) orelse return false).ast.sliced,
        .field_access => break,
        else => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, at) orelse return false;
            if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
            at = call.ast.fn_expr;
            break;
        },
    };
    const receiver = tree.nodeData(at).node_and_token[0];
    if (tree.nodeTag(receiver) != .identifier) return false;
    const local = (model.reference(receiver) orelse return false).declaration orelse return false;
    const record = model.declarations[@backingInt(local)];
    if (record.kind != .variable) return false;
    switch (model.scopes[@backingInt(record.scope)].kind) {
        .file, .container => return false,
        else => {},
    }
    if ((try c.facts.resolve(c.file, receiver)) != .instance) return false;
    // A loop between the local's scope and the store runs the store again after a growth.
    var up = store;
    while (model.parentOf(up)) |parent| : (up = parent) {
        if (parent == model.scopes[@backingInt(record.scope)].node) break;
        switch (tree.nodeTag(parent)) {
            .while_simple, .while_cont, .@"while", .for_simple, .@"for" => return false,
            else => {},
        }
    }
    const end = tree.lastToken(store);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const reference = model.reference(node) orelse continue;
        if (reference.declaration != local) continue;
        if (tree.nodeMainToken(node) > end) return false;
        const parent = model.parentOf(node) orelse return false;
        if (tree.nodeTag(parent) != .field_access) return false;
        // A list freed at all, wherever the free is written (a `defer` before the store runs
        // after it), leaves the borrow pointing at freed memory.
        const member = tree.tokenSlice(tree.nodeData(parent).node_and_token[1]);
        for ([_][]const u8{ "deinit", "clearAndFree", "shrinkAndFree", "toOwnedSlice", "toOwnedSliceSentinel", "moveToUnmanaged", "clearRetainingCapacity" }) |frees| {
            if (std.mem.eql(u8, member, frees)) return false;
        }
        var up_from = node;
        while (model.parentOf(up_from)) |outer| : (up_from = outer) {
            switch (tree.nodeTag(outer)) {
                .@"defer", .@"errdefer" => return false,
                .fn_decl => break,
                else => {},
            }
        }
    }
    return true;
}

/// Whether a value is a container declared in one of std's container namespaces.
fn ofStd(c: *Context, namespaces: []const ?Facts.Container, node: Ast.Node.Index) Context.Error!bool {
    const held = byPointer(try c.facts.resolve(c.file, node)) orelse return false;
    for (namespaces) |each| if (each) |namespace| if (held.file == namespace.file) return true;
    return false;
}

/// The containers std's `paths` name (a namespace's file, a type), each resolved once.
fn containersOf(c: *Context, rule: Rule, paths: []const []const u8) Context.Error![]const ?Facts.Container {
    const targets = try c.allocator.alloc(Governed.Target, paths.len);
    const indexes = try c.allocator.alloc(usize, paths.len);
    for (paths, targets, indexes, 0..) |path, *target, *index, i| {
        target.* = .{ .source = "std", .declaration = path };
        index.* = i;
    }
    var out: std.ArrayList(?Facts.Container) = .empty;
    for (try Governed.resolve(c, rule, targets, indexes)) |found| {
        var container: ?Facts.Container = null;
        for (found.decls) |decl| {
            const value = try c.facts.declaration((try c.facts.origin(decl)) orelse decl);
            if (value == .container) container = value.container;
        }
        // Kept in the order of `paths`, an unresolved one as null.
        try out.append(c.allocator, container);
    }
    return out.items;
}

fn find(containers: []const ?Facts.Container, held: Facts.Container) ?usize {
    for (containers, 0..) |each, i| if (each) |k| if (k.file == held.file and k.scope == held.scope) return i;
    return null;
}

/// The container a value holds by value: through optionals, error unions and arrays, never a
/// pointer, which borrows.
fn byValue(value: Facts.Value) ?Facts.Container {
    return switch (value) {
        .container, .instance => |k| k,
        .optional, .error_union, .array => |inner| byValue(inner.*),
        else => null,
    };
}

/// The container a value is or points at.
fn byPointer(value: Facts.Value) ?Facts.Container {
    return switch (value) {
        .container, .instance => |k| k,
        .pointer, .optional => |inner| byPointer(inner.*),
        else => null,
    };
}
