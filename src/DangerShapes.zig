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
            .field => (model.containerField(tree, decl.node) orelse continue).ast.type_expr.unwrap() orelse continue,
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

/// Whether the field read at `node` is moved out of its holder: the value (or its `.?`) of a
/// local's declaration whose block's next statement writes `null` to the same place, spelled
/// alike from the same declaration.
fn movedOut(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var read = node;
    var parent = model.parentOf(read) orelse return false;
    if (tree.nodeTag(parent) == .unwrap_optional) {
        read = parent;
        parent = model.parentOf(read) orelse return false;
    }
    const variable = tree.fullVarDecl(parent) orelse return false;
    if (variable.ast.init_node.unwrap() != read) return false;
    const block = model.parentOf(parent) orelse return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block) orelse return false;
    const at = std.mem.findScalar(Ast.Node.Index, statements, parent) orelse return false;
    if (at + 1 >= statements.len) return false;
    const next = statements[at + 1];
    if (tree.nodeTag(next) != .assign) return false;
    const place, const value = tree.nodeData(next).node_and_node;
    if (tree.nodeTag(value) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "null")) return false;
    if (!std.mem.eql(u8, tree.getNodeSource(place), tree.getNodeSource(node))) return false;
    const written = placeRoot(tree, place);
    const named = placeRoot(tree, node);
    if (tree.nodeTag(written) != .identifier or tree.nodeTag(named) != .identifier) return false;
    const first = (model.reference(written) orelse return false).declaration orelse return false;
    const second = (model.reference(named) orelse return false).declaration orelse return false;
    return first == second;
}

/// The name a place is reached from: `x` of `x.f`, `x.*.f`, `x.f.g`.
fn placeRoot(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = node;
    while (true) switch (tree.nodeTag(at)) {
        .field_access, .unwrap_optional, .grouped_expression => at = tree.nodeData(at).node_and_token[0],
        .deref => at = tree.nodeData(at).node,
        else => return at,
    };
}

/// What A015 says a field lent its owner should hold instead.
const advice = "aegis own.Owned holds an owner, and its borrow().* is what a type that lends its field is given";

/// A015 where ownership happens: the checked file's own writes and releases of a resource field
/// another file declares (`outside`). That type is lent what its field holds (0.3's raw handle is
/// lent, `own.OwnedIo` owned) as far as its own file shows, so an owner written into it (`s.f = opened()`, a literal of it), a release
/// of it, or an owner handed by value to a function that keeps it in a resource field some file
/// releases (`keeper.keep(opened())`, unless the caller releases it itself; its parameter reads as
/// a view in the keeper) is an owner held by hand here. A keeper that does not resolve, or a field's
/// address taken, is undecided.
fn foreign(c: *Context, rule: Rule, resources: []const ?Facts.Container) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
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
            // Moved out (`const out = child.stderr.?; child.stderr = null;`): the local holds
            // it, and the type no longer names what it held.
            if (movedOut(tree, &c.project.at(c.file).model, node)) continue;
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
        const call = (try Facts.calls.at(c.facts, c.file, node)) orelse continue;
        try handed(c, rule, resources, &call);
    }
    // A tuple's fields, named by position only, are no declarations: each is read where it is
    // written, as a field is.
    var buffer: [2]Ast.Node.Index = undefined;
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const container = tree.fullContainerDecl(&buffer, @fromBackingInt(@intCast(i))) orelse continue;
        for (container.ast.members) |node| {
            const field = c.project.at(c.file).model.containerField(tree, node) orelse continue;
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

/// A015 at `call`, which hands a std owner by value to a function that keeps it (`stores`): each
/// of a choice of callees read as one it calls. A callee that does not resolve, or a parameter
/// that takes the owner where which one is not known (`@call` given no tuple literal), may keep
/// it: undecided.
fn handed(c: *Context, rule: Rule, resources: []const ?Facts.Container, call: *const Facts.calls.Call) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const written: []const Ast.Node.Index = switch (call.args) {
        .known => |args| args,
        .unknown => if (tree.fullCall(&buffer, call.node)) |full| full.ast.params else &.{},
    };
    for (written, 0..) |argument, position| {
        const held = byValue(try c.facts.resolve(c.file, argument)) orelse continue;
        const which = find(resources, held) orelse continue;
        if (try filled(c, resources, c.file, argument) or try keptHere(c, argument)) continue;
        const at = tree.tokenStart(tree.nodeMainToken(argument));
        if (call.args == .unknown) {
            try c.undecided(rule, at, .unresolved, "an owner handed by value where which parameter takes it does not resolve, which may keep it");
            continue;
        }
        const callees: []const Facts.Decl = switch (call.callee) {
            .function => |*one| one[0..1],
            .choice => |each| each,
            .any => {
                try c.undecided(rule, at, .unresolved, "an owner handed by value to a function that does not resolve, which may keep it");
                continue;
            },
        };
        var unknown = false;
        for (callees) |callee| {
            const decl = (try originKnown(c, callee)) orelse {
                unknown = true;
                continue;
            };
            switch (try stores(c, resources, decl, position, 0)) {
                .no => {},
                .unknown => unknown = true,
                .yes => {
                    try c.at(rule, tree.nodeMainToken(argument), try c.allocator.print("a std.{s} owner handed by value to '{s}', which keeps it in a field it releases: the owner is held by hand there; {s}", .{ resource_paths[which], c.project.at(decl.file).model.declarations[@backingInt(decl.index)].name, advice }));
                    break;
                },
            }
        } else if (unknown) try c.undecided(rule, at, .unresolved, "an owner handed by value to a function outside the program that passes it where nothing resolves, which may keep it");
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
    if (depth >= 16) return .unknown;
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
    for (try Facts.calls.in(c.facts, c.file)) |*call| {
        if (c.inTest(tree.nodeMainToken(call.node))) continue;
        switch (call.callee) {
            .function => |*one| try bindingOf(c, rule, resources, paths, call, one[0..1]),
            // A choice of holders' members: each function the call may call, judged as one it
            // does.
            .choice => |each| try bindingOf(c, rule, resources, paths, call, each),
            // A callee Facts.calls does not read may still name its declaration (an alias of
            // std's). A call on a value of a generic's type parameter is judged at the
            // generic's bindings, with the type each gives.
            .any => |why| if (why != .generic) switch (try c.facts.definition(c.file, call.callee_expr)) {
                .decl => |*one| try bindingOf(c, rule, resources, paths, call, one[0..1]),
                .none => {},
                .unknown => |cause| if (cause != .generic) try unnamedBinding(c, rule, resources, call.node),
            },
        }
    }
}

/// A015 at `call`, a binding of each of `functions` that is a public generic.
fn bindingOf(c: *Context, rule: Rule, resources: []const ?Facts.Container, paths: []const []const u8, call: *const Facts.calls.Call, functions: []const Facts.Decl) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const node = call.node;
    for (functions) |callee| {
        const function = (try originKnown(c, callee)) orelse {
            try unnamedBinding(c, rule, resources, node);
            continue;
        };
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
        // over unless each return reads one held (`views`), its parameters this call's arguments.
        if (try heldBy(c, resources, try c.facts.resolve(function.file, result), 0) != .generic) continue;
        switch (try heldBy(c, resources, made, 0)) {
            .resource => |which| {
                const a_view = try views(c, resources, function, 0, &.{ .file = c.file, .call = call, .callee = function, .outer = null });
                if (!a_view) try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("this binding makes function '{s}' return a std.{s} by value that is no view of one held: an owner handed over; aegis own.Owned names its one owner and checks it is released once; a borrow of it is its borrow().*, which is never released", .{ record.name, paths[which] }));
            },
            .other => {},
            // A type the enclosing generic's parameters give is judged at its own bindings; one
            // outside any is this call's, not bound here (a choice of callees).
            .generic => if (!inGeneric(c, node)) try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "what this binding makes a generic return is not bound with its arguments: it may be a std resource by value"),
            .unknown => try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "what this binding makes a generic return does not resolve: it may be a std resource by value"),
        }
    }
}

/// Whether `node` is in a function with a type or `anytype` parameter, as `hasGenericParameter`
/// reads one.
fn inGeneric(c: *Context, node: Ast.Node.Index) bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var at = node;
    const function = while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) break parent;
    } else return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]) orelse return false;
    var it = proto.iterate(tree);
    while (it.next()) |param| {
        if (param.anytype_ellipsis3 != null) return true;
        if (param.type_expr) |type_expr| if (tree.nodeTag(type_expr) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(type_expr)), "type")) return true;
    }
    return false;
}

/// A015 at a call whose function does not resolve: a public generic's binding it may be, so
/// undecided where what it makes may hold a std resource by value. One that holds none hands no
/// owner over, whatever it calls; nor does one made a statement (`x.close();`, under `try` or
/// `defer`), whose value Zig compiles only as void. A type a parameter gives is judged at the
/// enclosing generic's bindings; outside one, it is the unnamed callee's to give: undecided.
fn unnamedBinding(c: *Context, rule: Rule, resources: []const ?Facts.Container, node: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    if (statementCall(tree, &c.project.at(c.file).model, node)) return;
    switch (try heldBy(c, resources, try c.facts.resolve(c.file, node), 0)) {
        .resource, .unknown => try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "which function this call calls does not resolve, and what it makes may hold a std resource by value: it may be a generic's owner handed over"),
        .generic => if (!inGeneric(c, node)) try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "which function this call calls does not resolve, and what it makes may hold a std resource by value: it may be a generic's owner handed over"),
        .other => {},
    }
}

/// Whether the call `node`, past `try` and parentheses, is a statement of a block or a `defer`.
fn statementCall(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) switch (tree.nodeTag(parent)) {
        .@"try", .grouped_expression => {},
        .block, .block_semicolon, .block_two, .block_two_semicolon, .@"defer", .@"errdefer" => return true,
        else => return false,
    };
    return false;
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
    const written = (c.project.at(field.file).model.containerField(tree, record.node) orelse return null).ast.type_expr.unwrap() orelse return null;
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
/// Whether `function`'s parameter at `position` is declared by a type parameter of a function
/// around it (`item: T` in `fn ArrayList(comptime T: type) type`).
fn genericElement(c: *Context, function: Facts.Decl, position: usize) bool {
    const tree = &c.project.at(function.file).file.tree;
    const model = &c.project.at(function.file).model;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(function.index)].node) orelse return false;
    var params = proto.iterate(tree);
    var at: usize = 0;
    const declared = while (params.next()) |param| : (at += 1) {
        if (at == position) break param.type_expr orelse return false;
    } else return false;
    if (tree.nodeTag(declared) != .identifier) return false;
    const id = (model.reference(declared) orelse return false).declaration orelse return false;
    return model.declarations[@backingInt(id)].kind == .parameter;
}

fn stores(c: *Context, resources: []const ?Facts.Container, function: Facts.Decl, position: usize, depth: u8) Context.Error!Stored {
    // std is given no owner by value: what keeps a handle (`File.Reader`, `File.Writer`) is lent
    // a copy of it. A container's element (`ArrayList(T).append(gpa, item: T)`, a parameter of a
    // type its type function is given) is kept whatever it is.
    if (try c.facts.standard(function.file)) return if (genericElement(c, function, position)) .yes else .no;
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
            const name = tree.tokenSlice(Model.initName(tree, value) orelse return .no);
            // A literal a local holds is kept where that local's field goes.
            if (literalLocal(tree, model, parent)) |id| return keptLocal(c, resources, file, id, name, depth);
            const holder = byValue(try c.facts.literalType(file, parent)) orelse return .unknown;
            return ownedField(c, resources, holder, name);
        }
        return .no;
    }
    const argument = switch (try argumentOf(c, file, node)) {
        .at => |at| at,
        .unknown => return .unknown,
        .none => return .no,
    };
    const Kept = struct { resources: []const ?Facts.Container, position: usize, depth: u8 };
    return eachCallee(c, &argument.call, Kept{ .resources = resources, .position = argument.position, .depth = depth }, struct {
        fn by(k: Kept, cc: *Context, callee: Facts.Decl) Context.Error!Stored {
            return stores(cc, k.resources, callee, k.position, k.depth + 1);
        }
    }.by);
}

/// Where a call takes `node` as an argument: the call and the position of the parameter it
/// binds, a bound receiver first, as Facts.calls reads it (`f(x)`, `x.f()`, `@call`'s tuple
/// element); unknown where the call passes it but which parameter takes it is not known.
const Argument = union(enum) { none, at: struct { call: Facts.calls.Call, position: usize }, unknown };

fn argumentOf(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!Argument {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const parent = model.parentOf(node) orelse return .none;
    var buffer: [2]Ast.Node.Index = undefined;
    // A receiver's parent is the callee `x.f`, a tuple element's `@call`'s third operand.
    const tuple = tree.fullArrayInit(&buffer, parent) != null;
    const holder = if (tree.nodeTag(parent) == .field_access or tuple) model.parentOf(parent) orelse return .none else parent;
    const call = (try Facts.calls.at(c.facts, file, holder)) orelse return .none;
    if (tuple and call.modifier == null) return .none;
    switch (call.args) {
        .known => |args| for (args, 0..) |arg, position| if (arg == node) return .{ .at = .{ .call = call, .position = position } },
        .unknown => return if (node == call.callee_expr) .none else .unknown,
    }
    return .none;
}

/// Whether the field `name` of the local `id` holds is kept where it is read: each read of the
/// local names a field (one passed whole, or a method called on it, may keep it).
fn keptLocal(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, id: Model.Declaration.Id, name: []const u8, depth: u8) Context.Error!Stored {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var result: Stored = .no;
    for (model.references) |reference| {
        if (reference.declaration != id) continue;
        const read = model.parentOf(reference.node) orelse return .unknown;
        if (tree.nodeTag(read) != .field_access or tree.nodeData(read).node_and_token[0] != reference.node) return .unknown;
        if (std.mem.eql(u8, tree.tokenSlice(tree.nodeData(read).node_and_token[1]), name)) {
            result = join(result, try kept(c, resources, file, read, depth));
            if (result == .yes) return .yes;
            continue;
        }
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, model.parentOf(read) orelse continue)) |call| if (call.ast.fn_expr == read) return .unknown;
    }
    return result;
}

/// The local a struct literal initializes, where one does (`const b: Box = .{ .f = f }`).
fn literalLocal(tree: *const Ast, model: *const Model, literal: Ast.Node.Index) ?Model.Declaration.Id {
    const parent = model.parentOf(literal) orelse return null;
    for (model.declarations, 0..) |decl, i| {
        if (decl.kind != .variable or decl.node != parent) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        if (variable.ast.init_node.unwrap() == literal) return @fromBackingInt(@intCast(i));
    }
    return null;
}

/// `by` for each function `call` may make: the one it names, or each of a choice (a build's,
/// a function pointer's every store), joined. One that may be any function may do anything
/// with what it is given.
fn eachCallee(c: *Context, call: *const Facts.calls.Call, context: anytype, comptime by: fn (@TypeOf(context), *Context, Facts.Decl) Context.Error!Stored) Context.Error!Stored {
    const choices: []const Facts.Decl = switch (call.callee) {
        .function => |*one| one[0..1],
        .choice => |each| each,
        .any => return .unknown,
    };
    var result: Stored = .no;
    for (choices) |choice| {
        result = join(result, try by(context, c, (try originKnown(c, choice)) orelse return .unknown));
        if (result == .yes) return .yes;
    }
    return result;
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
    const written = (c.project.at(field.file).model.containerField(tree, record.node) orelse return false).ast.type_expr.unwrap() orelse return false;
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
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
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
    if (tree.nodeTag(parent) == .address_of) return addressWrite(c, resources, file, parent);
    if (pointerCapture(tree, model, parent, target)) return .address;
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

/// How the field whose address `address` takes is written through it: by a copy of memory into
/// it (`@memcpy(std.mem.asBytes(&s.f), ...)`, `Facts.accesses.copyAt`), as `=` of the source's
/// value; through a constant local that keeps the pointer, by each use of it (`p.* = v`,
/// `p.handle = h`; a read of a member or of `p.*` writes nothing); handed anywhere else, it may
/// be written through.
fn addressWrite(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, address: Ast.Node.Index) Context.Error!Write {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const parent = model.parentOf(address) orelse return .address;
    if (try enclosingCopy(c, file, address)) |copy| {
        const place = tree.nodeData(address).node;
        // The field's bytes as the source are read, not written.
        if (copy.from == .place and copy.from.place == place) return .none;
        if (copy.into != .place or copy.into.place != place) return .address;
        return switch (copy.from) {
            .place, .value => |value| if (try filled(c, resources, file, value)) .none else .owner,
            .pointer => .unknown,
        };
    }
    const variable = tree.fullVarDecl(parent) orelse return .address;
    if (variable.ast.init_node.unwrap() != address or tree.tokenTag(variable.ast.mut_token) != .keyword_const) return .address;
    const local = for (model.declarations, 0..) |decl, i| {
        if (decl.kind == .variable and decl.node == parent) break @as(Model.Declaration.Id, @fromBackingInt(@intCast(i)));
    } else return .address;
    var out: Write = .none;
    for (model.references) |reference| {
        if (reference.declaration != local) continue;
        const use = model.parentOf(reference.node) orelse return .address;
        const write: Write = switch (tree.nodeTag(use)) {
            // `p.*`: written as the field is.
            .deref => try writeOf(c, resources, file, use),
            .field_access => if (tree.nodeData(use).node_and_token[0] != reference.node) .address else if (std.mem.eql(u8, tree.tokenSlice(tree.nodeData(use).node_and_token[1]), "handle")) try writeOf(c, resources, file, reference.node) else .none,
            else => .address,
        };
        out = switch (write) {
            .owner => return .owner,
            .address => .address,
            .unknown => if (out == .address) .address else .unknown,
            .none => out,
        };
    }
    return out;
}

/// The copy of memory the expression `node` is part of, within its statement: the first builtin
/// copy (`Facts.accesses.copyAt`) among the nodes around it.
fn enclosingCopy(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Facts.accesses.Copy {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (try Facts.accesses.copyAt(c.facts, file, parent)) |copy| return copy;
        switch (tree.nodeTag(parent)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon, .fn_decl => return null,
            else => {},
        }
    }
    return null;
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
    if ((c.project.at(file).model.containerField(own, decl.node) orelse return null).ast.value_expr.unwrap()) |default| {
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
    // A union's field read by a switch prong's capture (`.file => |x| x.close(io)`).
    const model = &c.project.at(file).model;
    for (own.nodes.items(.tag), 0..) |_, i| {
        const chosen = own.fullSwitch(@fromBackingInt(@intCast(i))) orelse continue;
        const subject = byPointer(try c.facts.resolve(file, chosen.ast.condition)) orelse continue;
        if (subject.file != holder.file or subject.scope != holder.scope) continue;
        for (chosen.ast.cases) |case_node| {
            const case = own.fullSwitchCase(case_node).?; // unreachable: a switch's cases are cases
            const named = for (case.ast.values) |value| {
                if (own.nodeTag(value) == .enum_literal and std.mem.eql(u8, own.tokenSlice(own.nodeMainToken(value)), decl.name)) break true;
            } else false;
            if (!named) continue;
            for (model.declarations, 0..) |each, d| {
                if (each.kind != .capture or each.node != case_node) continue;
                switch (try readsReleased(c, file, @fromBackingInt(@intCast(d)), 0)) {
                    .yes => return "that its file releases",
                    .unknown => doubt = true,
                    .no => {},
                }
            }
        }
    }
    // A write to part of it (`s.files[0] = opened()`), as accesses finds it.
    if (for (model.declarations, 0..) |each, i| {
        if (each.kind == .field and each.node == decl.node) break i;
    } else null) |at| {
        const in_file = [_]Project.FileId{file};
        var found_sites = Facts.accesses.writes(c.facts, .{ .field = .{ .file = file, .index = @fromBackingInt(@intCast(at)) } }, &in_file);
        while (try found_sites.next()) |site| {
            // A program the unit is read for may fill it with anything.
            if (site.kind == .open) doubt = true;
            if (!site.part or site.kind != .set) continue;
            const value = site.value orelse {
                doubt = true;
                continue;
            };
            if (!try filled(c, resources, site.file, value)) return owner;
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
    if (depth >= 8) return .unknown;
    const next = depth + 1;
    const parent = model.parentOf(node) orelse return .no;
    switch (tree.nodeTag(parent)) {
        // A slice of its memory (`(&f)[0..1]`, std's `closeMany` idiom) holds it.
        .unwrap_optional, .grouped_expression, .@"try", .address_of, .deref, .array_access, .slice, .slice_open, .slice_sentinel => return released(c, file, parent, next),
        // Compared, it is read for its value only.
        .equal_equal, .bang_equal, .less_than, .less_or_equal, .greater_than, .greater_or_equal => return .no,
        // In arithmetic (a `handle` summed) the result may still be it.
        .add, .sub, .mul, .add_wrap, .sub_wrap, .mul_wrap, .add_sat, .sub_sat, .mul_sat, .div, .mod, .bit_and, .bit_or, .bit_xor => return released(c, file, parent, next),
        .assign_add, .assign_sub, .assign_mul, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_div, .assign_mod, .assign_bit_and, .assign_bit_or, .assign_bit_xor => {
            const target = tree.nodeData(parent).node_and_node[0];
            // The target's own value goes back into it, whose other reads are followed.
            if (target == node) return .no;
            if (tree.nodeTag(target) != .identifier) return .unknown;
            const d = (model.reference(target) orelse return .unknown).declaration orelse return .unknown;
            return readsReleased(c, file, d, next);
        },
        // A destructure's target is written, not read; its value (a tuple) may hand it on.
        .assign_destructure => {
            return if (tree.assignDestructure(parent).ast.value_expr == node) .unknown else .no;
        },
        .field_access => {
            const name = tree.tokenSlice(tree.nodeData(parent).node_and_token[1]);
            if (std.mem.eql(u8, name, "handle")) return released(c, file, parent, next);
            if (!releasing(name)) return .no;
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, model.parentOf(parent) orelse return .no) orelse return .no;
            return if (call.ast.fn_expr == parent) .yes else .no;
        },
        .@"return" => return releasedReturn(c, file, parent, next),
        // A copy assigned: to a local, by each read of it; to another field, by each read of
        // that field of its holder's type; to `_`, nowhere; through anything else, maybe.
        .assign => {
            const target, const value = tree.nodeData(parent).node_and_node;
            if (value != node) return .no;
            switch (tree.nodeTag(target)) {
                .identifier => {
                    if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) return .no;
                    const d = (model.reference(target) orelse return .unknown).declaration orelse return .unknown;
                    return readsReleased(c, file, d, next);
                },
                .field_access => {
                    const receiver, const name = tree.nodeData(target).node_and_token;
                    const holder = byPointer(try c.facts.resolve(file, receiver)) orelse return .unknown;
                    return typeReleased(c, holder, tree.tokenSlice(name), next);
                },
                else => return .unknown,
            }
        },
        else => if (carrier(tree, model, node)) |whole| return released(c, file, whole, next),
    }
    switch (try argumentOf(c, file, node)) {
        .at => |at| return releasesParameter(c, &at.call, at.position, next),
        .unknown => return .unknown,
        .none => {},
    }
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&buffer, parent) != null) return .no;
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
        for (literal.ast.elements, 0..) |element, position| if (element == node) return elementReleased(c, file, parent, position, null, next);
        return .no;
    }
    // Switched on, by each read of its prongs' captures (`.file => |x| x.close(io)`).
    if (tree.fullSwitch(parent)) |chosen| {
        if (chosen.ast.condition != node) return .no;
        var result: Stored = .no;
        for (chosen.ast.cases) |case| for (model.declarations, 0..) |decl, i| {
            if (decl.kind != .capture or decl.node != case) continue;
            result = join(result, try readsReleased(c, file, @fromBackingInt(@intCast(i)), next));
            if (result == .yes) return .yes;
        };
        return result;
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
    // A condition that captures nothing reads it for its value only.
    if (tree.fullIf(parent)) |branch| if (branch.ast.cond_expr == node and branch.payload_token == null) return .no;
    if (tree.fullWhile(parent)) |loop| if (loop.ast.cond_expr == node and loop.payload_token == null) return .no;
    // Any other place it goes is not followed: it may be released there.
    return .unknown;
}

/// What a function returns (`ret`, its `return`) is released where the function's caller
/// releases it.
fn releasedReturn(c: *Context, file: Project.FileId, ret: Ast.Node.Index, depth: u8) Context.Error!Stored {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const function = enclosingFunction(model, tree, ret) orelse return .no;
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
        result = join(result, try releasedCall(c, use.file, use.node, depth));
        if (result == .yes) return .yes;
    }
    for (model.references) |reference| {
        if (reference.declaration != id) continue;
        result = join(result, try releasedCall(c, file, reference.node, depth));
        if (result == .yes) return .yes;
    }
    return result;
}

/// The expression whose value is `node`'s whole, where its parent hands it on: a conversion
/// (`@as`), an `if`'s or a switch prong's result, either side of `orelse` or `catch`, a
/// labeled `break`'s value (its block or loop).
fn carrier(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Ast.Node.Index {
    const parent = model.parentOf(node) orelse return null;
    switch (tree.nodeTag(parent)) {
        .builtin_call_two, .builtin_call_two_comma => {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, parent, &buffer);
            if (args.len != 2 or args[1] != node or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parent)), "@as")) return null;
            return parent;
        },
        .@"orelse", .@"catch" => return parent,
        .@"break" => {
            const label, const value = tree.nodeData(parent).opt_token_and_opt_node;
            if (value.unwrap() != node) return null;
            return breakTarget(tree, model, parent, label.unwrap() orelse return null);
        },
        else => {},
    }
    if (tree.fullSwitchCase(parent)) |case| {
        if (case.ast.target_expr != node) return null;
        return model.parentOf(parent);
    }
    if (tree.fullIf(parent)) |branch| {
        if (branch.ast.cond_expr == node) return null;
        return parent;
    }
    return null;
}

/// The labeled block or loop `label` names around the `break` at `jump`.
fn breakTarget(tree: *const Ast, model: *const Model, jump: Ast.Node.Index, label: Ast.TokenIndex) ?Ast.Node.Index {
    const name = tree.tokenSlice(label);
    var at = jump;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                const lbrace = tree.nodeMainToken(parent);
                if (lbrace >= 2 and tree.tokenTag(lbrace - 1) == .colon and std.mem.eql(u8, tree.tokenSlice(lbrace - 2), name)) return parent;
            },
            .@"while", .while_simple, .while_cont, .@"for", .for_simple => {
                var first = tree.firstToken(parent);
                if (tree.tokenTag(first) == .keyword_inline) first += 1;
                if (tree.tokenTag(first) == .identifier and tree.tokenTag(first + 1) == .colon and std.mem.eql(u8, tree.tokenSlice(first), name)) return parent;
            },
            .fn_decl => return null,
            else => {},
        }
    }
    return null;
}

/// Whether the field `name` of a struct literal is `released`: where the value it makes goes
/// (`madeReleased`), a local it initializes by each read of the local.
fn literalReleased(c: *Context, file: Project.FileId, literal: Ast.Node.Index, name: []const u8, depth: u8) Context.Error!Stored {
    if (depth >= 8) return .unknown;
    if (c.project.at(file).model.parentOf(literal) == null) return .unknown;
    return madeReleased(c, file, literal, name, byValue(try c.facts.literalType(file, literal)), depth);
}

/// Whether the field `name` of the value `node` in `file` makes (a struct literal no local
/// holds, a call that returns one) is `released`, following that value where Facts.accesses
/// reads it to go: on through a carrier, or its function's return to each call of it; that
/// field read, by the read; another field read, or it compared or discarded, not; a method
/// called on it or it handed to a function, by the parameter that takes it (std's by its
/// name); a local it initializes, by each read of the local; its address, as it is; kept in
/// another literal's field, by that field's reads. Anywhere else (stored), by each read of that
/// field of `holder`, its type, in the program (`typeReleased`),
/// or maybe where its type does not resolve: `dirOf(h).openDir(...)` in a function that makes
/// a `std.Io.Dir` of a handle is that call's, not every `Io.Dir`'s.
fn madeReleased(c: *Context, file: Project.FileId, node: Ast.Node.Index, name: []const u8, holder: ?Facts.Container, depth: u8) Context.Error!Stored {
    if (depth >= 8) return .unknown;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const next = depth + 1;
    switch (try Facts.accesses.useOf(c.facts, file, node)) {
        .carried => |via| return madeReleased(c, file, via.into, name, holder, next),
        .returned => |ret| {
            const function = enclosingFunction(model, tree, ret) orelse return .unknown;
            const proto = tree.nodeData(function).node_and_node[0];
            const id = for (model.declarations, 0..) |decl, i| {
                if (decl.kind == .function and decl.node == proto) break @as(Model.Declaration.Id, @fromBackingInt(@intCast(i)));
            } else return .unknown;
            var result: Stored = .no;
            for (try c.facts.memberUses(model.declarations[@backingInt(id)].name)) |use| {
                const callee = try c.facts.resolve(use.file, use.node);
                if (callee != .function or callee.function.file != file or callee.function.index != id) continue;
                result = join(result, try madeByCall(c, use.file, use.node, name, holder, next));
                if (result == .yes) return .yes;
            }
            for (model.references) |reference| {
                if (reference.declaration != id) continue;
                result = join(result, try madeByCall(c, file, reference.node, name, holder, next));
                if (result == .yes) return .yes;
            }
            return result;
        },
        .discarded, .compared => return .no,
        // A pointer to it is read by the same fields, and handed on as it is.
        .address => |taken| return madeReleased(c, file, taken, name, holder, next),
        .member => |access| {
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeData(access).node_and_token[1]), name)) return released(c, file, access, next);
            // A method called on it is given it as its receiver; another field read is not it.
            const call = (try Facts.calls.at(c.facts, file, model.parentOf(access) orelse return .no)) orelse return .no;
            if (call.callee_expr != access) return .no;
            return switch (call.receiver) {
                .bound => madeHanded(c, &call, 0, name, holder, next),
                .none => .no,
                .unknown => .unknown,
            };
        },
        .argument => |argument| {
            const call = (try Facts.calls.at(c.facts, file, argument.call)) orelse return .unknown;
            const args = switch (call.args) {
                .known => |known| known,
                .unknown => return .unknown,
            };
            return madeHanded(c, &call, std.mem.findScalar(Ast.Node.Index, args, node) orelse return .unknown, name, holder, next);
        },
        .initializes => |declaration| {
            for (model.declarations, 0..) |decl, i| {
                if (decl.kind != .variable or decl.node != declaration) continue;
                var result: Stored = .no;
                for (model.references) |reference| {
                    if (@backingInt(reference.declaration orelse continue) != i) continue;
                    result = join(result, try madeReleased(c, file, reference.node, name, holder, next));
                    if (result == .yes) return .yes;
                }
                return result;
            }
        },
        // Over it, a store's target holds another value from there.
        .written => return .no,
        .dereferenced => |deref| return madeReleased(c, file, deref, name, holder, next),
        // An `if`'s or a `while`'s condition, by each read of what it captures of it.
        .tested => |branch| return madeCaptured(c, file, branch, node, name, holder, next),
        .switched => |at| return madeSwitched(c, file, at, name, next),
        .stored => |store| if (try madeStored(c, file, store, name, holder, next)) |answer| return answer,
        // Kept in another literal's field (`.{ .lent = dir }`, held.Parent's): where each read
        // of that field of the literal's type gives it, a prong's capture of it among them.
        .field_of => |field| {
            const keeper = byValue(try c.facts.literalType(file, field.literal)) orelse return .unknown;
            return keptReleased(c, keeper, tree.tokenSlice(field.name), name, holder);
        },
        else => {},
    }
    return typeReleased(c, holder orelse return .unknown, name, depth);
}

/// `madeReleased` of what the `if` or `while` `branch` captures of `node`, its condition.
fn madeCaptured(c: *Context, file: Project.FileId, branch: Ast.Node.Index, node: Ast.Node.Index, name: []const u8, holder: ?Facts.Container, depth: u8) Context.Error!Stored {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var result: Stored = .no;
    for (model.declarations, 0..) |decl, i| {
        if (decl.kind != .capture or decl.node != branch or !captures(tree, branch, decl.token, node)) continue;
        for (model.references) |reference| {
            if (@backingInt(reference.declaration orelse continue) != i) continue;
            result = join(result, try madeReleased(c, file, reference.node, name, holder, depth));
            if (result == .yes) return .yes;
        }
    }
    return result;
}

/// `madeReleased` of a value the switch `at` is on, by what its prongs capture: one naming the
/// field, that field by its reads; one naming other tags only, not it; any other (`else`,
/// `inline else`), by its reads.
fn madeSwitched(c: *Context, file: Project.FileId, at: Ast.Node.Index, name: []const u8, depth: u8) Context.Error!Stored {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const chosen = tree.fullSwitch(at) orelse return .unknown;
    var result: Stored = .no;
    for (chosen.ast.cases) |case_node| {
        const case = tree.fullSwitchCase(case_node).?; // unreachable: a switch's cases are cases
        if (case.payload_token == null) continue;
        var others = case.ast.values.len != 0 and case.inline_token == null;
        // A prong naming only other tags (Facts.tagNamed) does not take it; one naming it, or a
        // value naming no tag known, may.
        for (case.ast.values) |value| {
            const tag = (try c.facts.tagNamed(file, value)) orelse {
                others = false;
                continue;
            };
            if (std.mem.eql(u8, tag.name, name)) others = false;
        }
        if (others) continue;
        for (model.declarations, 0..) |decl, i| {
            if (decl.kind != .capture or decl.node != case_node) continue;
            result = join(result, try readsReleased(c, file, @fromBackingInt(@intCast(i)), depth));
            if (result == .yes) return .yes;
        }
    }
    return result;
}

/// `madeReleased` of a value the store `store` writes, by the place its target names
/// (Facts.accesses.pathOf): a local of the function, by each read of it; a field, by that
/// field's reads (`keptReleased`); null for another place. A variable outside a function may be
/// read from any file: unknown.
fn madeStored(c: *Context, file: Project.FileId, store: Facts.accesses.Site, name: []const u8, holder: ?Facts.Container, depth: u8) Context.Error!?Stored {
    const model = &c.project.at(file).model;
    const target = store.target orelse return null;
    const path = try Facts.accesses.pathOf(c.facts, file, target);
    const place = path.steps[0];
    switch (place.kind) {
        .root => {
            const id = switch (path.root) {
                .decl => |d| d,
                .none => return null,
                .unknown => return .unknown,
            };
            if (id.file != file) return .unknown;
            switch (model.scopes[@backingInt(model.declarations[@backingInt(id.index)].scope)].kind) {
                .file, .container => return .unknown,
                else => {},
            }
            var result: Stored = .no;
            for (model.references) |reference| {
                if (reference.declaration != id.index or reference.node == target) continue;
                result = join(result, try madeReleased(c, file, reference.node, name, holder, depth));
                if (result == .yes) return .yes;
            }
            return result;
        },
        .field => {
            const keeper = byPointer(place.holder orelse return .unknown) orelse return .unknown;
            return try keptReleased(c, keeper, place.name orelse return .unknown, name, holder);
        },
        else => return null,
    }
}

/// `madeReleased` of what the call whose callee is `callee` (a reference to the function, or a
/// member naming it) makes; a reference that is no call's callee hands the function on.
fn madeByCall(c: *Context, file: Project.FileId, callee: Ast.Node.Index, name: []const u8, holder: ?Facts.Container, depth: u8) Context.Error!Stored {
    const tree = &c.project.at(file).file.tree;
    const parent = c.project.at(file).model.parentOf(callee) orelse return .no;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, parent) orelse return .no;
    if (call.ast.fn_expr != callee) return .no;
    return madeReleased(c, file, parent, name, holder, depth);
}

/// `madeReleased` of a value `call` hands its callee at `position`, a receiver first: by each
/// read of that parameter of a program function, by its name for std's.
fn madeHanded(c: *Context, call: *const Facts.calls.Call, position: usize, name: []const u8, holder: ?Facts.Container, depth: u8) Context.Error!Stored {
    const Handed = struct { position: usize, name: []const u8, holder: ?Facts.Container, depth: u8 };
    return eachCallee(c, call, Handed{ .position = position, .name = name, .holder = holder, .depth = depth }, struct {
        fn by(h: Handed, cc: *Context, callee: Facts.Decl) Context.Error!Stored {
            const record = cc.project.at(callee.file).model.declarations[@backingInt(callee.index)];
            if (!try cc.facts.program(callee.file)) return if (releasing(record.name)) .yes else .no;
            const id = switch (parameterAt(cc, callee, h.position)) {
                .declared => |id| id,
                .none => return .no,
                .unknown => return .unknown,
            };
            var result: Stored = .no;
            for (cc.project.at(callee.file).model.references) |reference| {
                if (reference.declaration != id) continue;
                result = join(result, try madeReleased(cc, callee.file, reference.node, h.name, h.holder, h.depth));
                if (result == .yes) return .yes;
            }
            return result;
        }
    }.by);
}

/// Whether a read of the field `name` of `holder`'s values anywhere in the program is
/// `released` (an `@field` by a computed name on one may be).
fn typeReleased(c: *Context, holder: Facts.Container, name: []const u8, depth: u8) Context.Error!Stored {
    const field = c.facts.member(holder, name) orelse return holderReleased(c, holder, name, depth);
    return summarized(c, .{ .of = .field, .decl = field });
}

/// `typeReleased` of the field `field` declares.
fn fieldReleased(c: *Context, field: Facts.Decl, depth: u8) Context.Error!Stored {
    const record = c.project.at(field.file).model.declarations[@backingInt(field.index)];
    return holderReleased(c, .{ .file = field.file, .scope = record.scope }, record.name, depth);
}

fn holderReleased(c: *Context, holder: Facts.Container, name: []const u8, depth: u8) Context.Error!Stored {
    var result: Stored = .no;
    for (try fieldUses(c, name)) |use| {
        const receiver = byPointer(try c.facts.resolve(use.file, use.receiver)) orelse continue;
        if (receiver.file != holder.file or receiver.scope != holder.scope) continue;
        const answer = try released(c, use.file, use.node, depth + 1);
        result = join(result, if (use.named) answer else if (answer == .no) .no else .unknown);
        if (result == .yes) return .yes;
    }
    // A union's field is read by what a prong captures of it (`prongReads`).
    const prongs = try prongReads(c, holder, name);
    if (prongs.unknown) result = join(result, .unknown);
    for (prongs.captures) |capture| {
        result = join(result, try readsReleased(c, capture.file, capture.decl, depth + 1));
        if (result == .yes) return .yes;
    }
    return result;
}

/// What a prong captures of a union's field, wherever a value of `holder` is switched on
/// (`.lent => |d| d`): a prong naming it (`named`), and one naming no tag (`else`, `inline
/// else`) or one otherwise, which may capture it, or the union itself. A subject that does not
/// resolve may be one (`unknown`).
const ProngReads = struct {
    const Capture = struct { file: Project.FileId, decl: Model.Declaration.Id, named: bool };
    captures: []const Capture,
    unknown: bool,
};

fn prongReads(c: *Context, holder: Facts.Container, name: []const u8) Context.Error!ProngReads {
    var found: std.ArrayList(ProngReads.Capture) = .empty;
    var unknown = false;
    const prongs = try unionProngs(c);
    const named: []const Prong = if (prongs.named.get(name)) |list| list.items else &.{};
    for ([_][]const Prong{ named, prongs.others.items }, [_]bool{ true, false }) |each, by_name| for (each) |prong| {
        const subject = try c.facts.resolve(prong.file, prong.subject);
        const switched = byPointer(subject) orelse {
            if (subject == .unknown) unknown = true;
            continue;
        };
        if (switched.file != holder.file or switched.scope != holder.scope) continue;
        for (c.project.at(prong.file).model.declarations, 0..) |decl, d| {
            if (decl.kind != .capture or decl.node != prong.case) continue;
            try found.append(c.allocator, .{ .file = prong.file, .decl = @fromBackingInt(@intCast(d)), .named = by_name });
        }
    };
    return .{ .captures = found.items, .unknown = unknown };
}

/// What `madeReleased` reads of a value kept in a field: whether the field `name` of the values
/// the field `field` of `keeper` holds is released, each read of that field (`x.lent`, a prong's
/// capture of it) followed as the value it gives; a prong that may capture the union itself, by
/// its reads whole (`released`). Read once for the run, from no depth; one met again while still
/// being read adds nothing there, and an answer of no read meanwhile is not kept (`summarized`).
const KeptReads = struct {
    found: std.StringHashMapUnmanaged(Stored) = .empty,
    open: std.StringHashMapUnmanaged(void) = .empty,
    met_open: usize = 0,
};

fn keptReleased(c: *Context, keeper: Facts.Container, field: []const u8, name: []const u8, holder: ?Facts.Container) Context.Error!Stored {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const state = try c.facts.memo(KeptReads);
    const of: [2]u32 = if (holder) |h| .{ @backingInt(h.file), @backingInt(h.scope) } else .{ std.math.maxInt(u32), 0 };
    const key = try c.allocator.print("{d}:{d}:{s}:{s}:{d}:{d}", .{ @backingInt(keeper.file), @backingInt(keeper.scope), field, name, of[0], of[1] });
    if (state.found.get(key)) |answer| return answer;
    if (state.open.contains(key)) {
        state.met_open += 1;
        return .no;
    }
    try state.open.put(c.allocator, key, {});
    const met_open = state.met_open;
    const result = try keptReads(c, keeper, field, name, holder);
    _ = state.open.remove(key);
    if (result != .no or state.met_open == met_open) try state.found.put(c.allocator, key, result);
    return result;
}

fn keptReads(c: *Context, keeper: Facts.Container, field: []const u8, name: []const u8, holder: ?Facts.Container) Context.Error!Stored {
    var result: Stored = .no;
    for (try fieldUses(c, field)) |use| {
        const receiver = byPointer(try c.facts.resolve(use.file, use.receiver)) orelse continue;
        if (receiver.file != keeper.file or receiver.scope != keeper.scope) continue;
        if (!use.named) {
            if (try released(c, use.file, use.node, 0) != .no) result = join(result, .unknown);
            continue;
        }
        result = join(result, try madeReleased(c, use.file, use.node, name, holder, 0));
        if (result == .yes) return .yes;
    }
    const prongs = try prongReads(c, keeper, field);
    if (prongs.unknown) result = join(result, .unknown);
    for (prongs.captures) |capture| {
        if (!capture.named) {
            result = join(result, try readsReleased(c, capture.file, capture.decl, 0));
        } else for (c.project.at(capture.file).model.references) |reference| {
            if (reference.declaration != capture.decl) continue;
            result = join(result, try madeReleased(c, capture.file, reference.node, name, holder, 0));
            if (result == .yes) return .yes;
        }
        if (result == .yes) return .yes;
    }
    return result;
}

/// A switch's prong that captures a payload: the switch's subject and the prong.
const Prong = struct { file: Project.FileId, subject: Ast.Node.Index, case: Ast.Node.Index };

/// The prongs of the program's switches that capture a payload, made once per run
/// (`Facts.memo`): by each tag a prong names (Facts.tagNamed), and those that name none known
/// (`else`, `inline else`, a value whose tag does not resolve), which may capture any.
const UnionProngs = struct {
    built: bool = false,
    named: std.StringHashMapUnmanaged(std.ArrayList(Prong)) = .empty,
    others: std.ArrayList(Prong) = .empty,
};

fn unionProngs(c: *Context) Context.Error!*const UnionProngs {
    const index = try c.facts.memo(UnionProngs);
    if (index.built) return index;
    index.built = true;
    const gpa = c.facts.gpa;
    for (c.project.sources) |*source| {
        if (!try c.facts.program(source.id)) continue;
        const tree = &source.file.tree;
        for (0..tree.nodes.len) |i| {
            const chosen = tree.fullSwitch(@fromBackingInt(@intCast(i))) orelse continue;
            for (chosen.ast.cases) |case_node| {
                const case = tree.fullSwitchCase(case_node).?; // unreachable: a switch's cases are cases
                if (case.payload_token == null) continue;
                const prong: Prong = .{ .file = source.id, .subject = chosen.ast.condition, .case = case_node };
                var by_literal = case.ast.values.len != 0 and case.inline_token == null;
                for (case.ast.values) |value| {
                    const tag = (try c.facts.tagNamed(source.id, value)) orelse {
                        by_literal = false;
                        continue;
                    };
                    const entry = try index.named.getOrPut(gpa, try gpa.dupe(u8, tag.name));
                    if (!entry.found_existing) entry.value_ptr.* = .empty;
                    try entry.value_ptr.append(gpa, prong);
                }
                if (!by_literal) try index.others.append(gpa, prong);
            }
        }
    }
    return index;
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
    for ([_][]const u8{ "close", "closeMany", "deinit", "kill", "wait" }) |each| if (std.mem.eql(u8, name, each)) return true;
    return false;
}

/// Whether a call releases its argument at `position`: a program function by a release of that
/// parameter in its body (`released`), std's by its name (`close`, `deinit`, `kill`, `wait`), a
/// choice per build by each (`eachCallee`), and one that is no declared function (a function
/// pointer, a value that does not resolve) may.
fn releasesParameter(c: *Context, call: *const Facts.calls.Call, position: usize, depth: u8) Context.Error!Stored {
    const At = struct { position: usize, depth: u8 };
    return eachCallee(c, call, At{ .position = position, .depth = depth }, struct {
        fn by(at: At, cc: *Context, callee: Facts.Decl) Context.Error!Stored {
            return releasesBy(cc, callee, at.position, at.depth);
        }
    }.by);
}

/// `releasesParameter` where the call is to `callee`, `position` among its parameters.
fn releasesBy(c: *Context, callee: Facts.Decl, position: usize, depth: u8) Context.Error!Stored {
    const record = c.project.at(callee.file).model.declarations[@backingInt(callee.index)];
    if (!try c.facts.program(callee.file)) return if (releasing(record.name)) .yes else .no;
    _ = depth;
    return switch (parameterAt(c, callee, position)) {
        .declared => |id| summarized(c, .{ .of = .parameter, .decl = .{ .file = callee.file, .index = id } }),
        .none => .no,
        .unknown => .unknown,
    };
}

/// What `released` finds of a function's parameter (by each read of it in the body) or of a
/// type's field (by each read of that field in the program): where chains of calls and fields
/// meet again, each read once for the run, from no depth, so how far it is reached from does not
/// cut it short. One met again while it is still being read adds no release of its own: it is no
/// there, and an answer of no read meanwhile is not kept, being read again where asked.
const Summary = struct { of: enum { parameter, field }, decl: Facts.Decl };
const Summaries = struct {
    found: std.AutoHashMapUnmanaged(Summary, Stored) = .empty,
    open: std.AutoHashMapUnmanaged(Summary, void) = .empty,
    /// How many times one still being read was met again.
    met_open: usize = 0,
};

fn summarized(c: *Context, summary: Summary) Context.Error!Stored {
    const state = try c.facts.memo(Summaries);
    if (state.found.get(summary)) |answer| return answer;
    if (state.open.contains(summary)) {
        state.met_open += 1;
        return .no;
    }
    try state.open.put(c.facts.gpa, summary, {});
    const met_open = state.met_open;
    const result = switch (summary.of) {
        .parameter => try readsReleased(c, summary.decl.file, summary.decl.index, 0),
        .field => try fieldReleased(c, summary.decl, 0),
    };
    _ = state.open.remove(summary);
    if (result != .no or state.met_open == met_open) try state.found.put(c.facts.gpa, summary, result);
    return result;
}

/// The parameter of the program function `callee` at `position`, a method's receiver first:
/// none where it has no name or no parameter is there, which nothing in its body reads.
const Parameter = union(enum) { declared: Model.Declaration.Id, none, unknown };

fn parameterAt(c: *Context, callee: Facts.Decl, position: usize) Parameter {
    const target = &c.project.at(callee.file).file.tree;
    const target_model = &c.project.at(callee.file).model;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = target.fullFnProto(&proto_buffer, target_model.declarations[@backingInt(callee.index)].node) orelse return .unknown;
    var params = proto.iterate(target);
    var at: usize = 0;
    const name_token = while (params.next()) |param| : (at += 1) {
        if (at == position) break param.name_token orelse return .none;
    } else return .none;
    for (target_model.declarations, 0..) |decl, i| {
        if (decl.kind == .parameter and decl.token == name_token) return .{ .declared = @fromBackingInt(@intCast(i)) };
    }
    return .none;
}

/// Whether the element at `position` of a tuple (`tuple`: its literal, or a parameter or carrier
/// that holds it on the way, read under `env`) is `released` where the tuple goes, as
/// Facts.accesses reads each use: handed to a function, by each read of the parameter that takes
/// it, read under the binding that call makes (`Facts.bind`); given as `@call`'s arguments, by
/// the parameter at that position of each function Facts.calls reads that `@call` to make there
/// (`retrying(io, f, .{ dir, &path })` and its `@call(.auto, f, args)`). Anywhere else it may be.
/// The tuple's hand-ons are counted apart (`hops`, as far as `Facts.bind` reads a chain): the
/// function its element reaches reads it one step past `depth`, where its tuple was made.
fn elementReleased(c: *Context, file: Project.FileId, tuple: Ast.Node.Index, position: usize, env: ?*const Facts.Env, depth: u8) Context.Error!Stored {
    return handedElement(c, file, tuple, position, env, depth, 0);
}

fn handedElement(c: *Context, file: Project.FileId, tuple: Ast.Node.Index, position: usize, env: ?*const Facts.Env, depth: u8, hops: u8) Context.Error!Stored {
    if (depth >= 8 or hops >= 32) return .unknown;
    switch (try Facts.accesses.useOf(c.facts, file, tuple)) {
        .carried => |via| return handedElement(c, file, via.into, position, env, depth, hops + 1),
        // `@TypeOf(args)` reads its type, no value.
        .discarded, .compared, .typed => return .no,
        // Kept in a literal's field (`.{ .arguments = args }`): by each read of that field of the
        // literal's type, read under this binding (a type its function declares, as `syncCall`'s
        // `Job` and its `run`, reads the function's parameters as its call binds them).
        .field_of => |field| {
            const tree = &c.project.at(file).file.tree;
            const holder = byValue(try c.facts.literalType(file, field.literal)) orelse return .unknown;
            var result: Stored = .no;
            for (try fieldUses(c, tree.tokenSlice(field.name))) |use| {
                const receiver = byPointer(try c.facts.resolve(use.file, use.receiver)) orelse continue;
                if (receiver.file != holder.file or receiver.scope != holder.scope) continue;
                const answer = try handedElement(c, use.file, use.node, position, env, depth, hops + 1);
                result = join(result, if (use.named) answer else if (answer == .no) .no else .unknown);
                if (result == .yes) return .yes;
            }
            return result;
        },
        .builtin_argument => |argument| {
            const call = (try Facts.calls.under(c.facts, env, file, argument.call)) orelse return .unknown;
            // `@call`'s tuple binds no receiver: its element at `position` is that parameter.
            if (call.modifier == null or argument.position != 2) return .unknown;
            return releasesParameter(c, &call, position, depth + 1);
        },
        .argument => |argument| {
            const call = (try Facts.calls.under(c.facts, env, file, argument.call)) orelse return .unknown;
            const args = switch (call.args) {
                .known => |known| known,
                .unknown => return .unknown,
            };
            const Handed = struct { file: Project.FileId, call: Ast.Node.Index, at: usize, position: usize, env: ?*const Facts.Env, depth: u8, hops: u8 };
            const given: Handed = .{ .file = file, .call = argument.call, .at = std.mem.findScalar(Ast.Node.Index, args, tuple) orelse return .unknown, .position = position, .env = env, .depth = depth, .hops = hops + 1 };
            return eachCallee(c, &call, given, struct {
                fn by(h: Handed, cc: *Context, callee: Facts.Decl) Context.Error!Stored {
                    const record = cc.project.at(callee.file).model.declarations[@backingInt(callee.index)];
                    if (!try cc.facts.program(callee.file)) return if (releasing(record.name)) .yes else .no;
                    const id = switch (parameterAt(cc, callee, h.at)) {
                        .declared => |id| id,
                        .none => return .no,
                        .unknown => return .unknown,
                    };
                    var buffer: [1]Ast.Node.Index = undefined;
                    const written = cc.project.at(h.file).file.tree.fullCall(&buffer, h.call) orelse return .unknown;
                    const reading = try cc.facts.bind(h.file, written, callee, h.env);
                    var result: Stored = .no;
                    for (cc.project.at(callee.file).model.references) |reference| {
                        if (reference.declaration != id) continue;
                        result = join(result, try handedElement(cc, callee.file, reference.node, h.position, reading, h.depth, h.hops));
                        if (result == .yes) return .yes;
                    }
                    return result;
                }
            }.by);
        },
        else => return .unknown,
    }
}

/// Whether `node` in `file` is an argument of a call that neither releases it (`released`) nor
/// keeps it (`kept`, std's containers among them): a copy of a std handle that call is lent.
pub fn lentArgument(c: *Context, rule: Rule, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const parent = c.project.at(file).model.parentOf(node) orelse return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, parent) orelse return false;
    for (call.ast.params) |argument| if (argument == node) {
        if (try released(c, file, node, 0) != .no) return false;
        return try kept(c, try containersOf(c, rule, &resource_paths), file, node, 0) == .no;
    };
    return false;
}

/// `decl`'s origin, itself where it is its own; null where which it is is not known.
fn originKnown(c: *Context, decl: Facts.Decl) Context.Error!?Facts.Decl {
    return switch (try c.facts.origin(decl)) {
        .decl => |found| found,
        .none => decl,
        .unknown => null,
    };
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
            .function => |decl| (try originKnown(c, decl)) orelse {
                try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "which function this call calls does not resolve: it may acquire a std resource by value");
                return false;
            },
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

/// Whether `value` holds a std resource by value, as an acquisition's result does
/// (`acquiresHandle`): one a generic's binding makes may be acquired there, a view of one held
/// or not.
pub fn holdsHandle(c: *Context, rule: Rule, value: Facts.Value) Context.Error!bool {
    const held = byValue(value) orelse return false;
    return find(try containersOf(c, rule, &resource_paths), held) != null;
}

/// Whether what the call `node` gives in the reading `env` (a generic's binding) is lent, as
/// `acquiresHandle` reads a call it does not acquire by (`callViewed`), its callee the one the
/// binding makes it: `store.gitDir()` on `store: anytype` bound to a store whose `gitDir`
/// returns its field. No call there, or one that does not resolve, is no loan.
pub fn lentUnder(c: *Context, rule: Rule, env: *const Facts.Env, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const call = (try Facts.calls.under(c.facts, env, file, node)) orelse return false;
    return callViewed(c, try containersOf(c, rule, &resource_paths), file, &call, 0, null);
}

/// A call of the program's function whose returns `views` reads: there a parameter of the
/// callee is the argument the call passes at it, read where the call is (`outer` the binding in
/// force there).
const Binding = struct { file: Project.FileId, call: *const Facts.calls.Call, callee: Facts.Decl, outer: ?*const Binding };

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
    // Where which argument it binds is not known, it is no view: what it gives is an owner.
    const args = switch (binding.call.args) {
        .known => |args| args,
        .unknown => return false,
    };
    if (position >= args.len) return false;
    return viewed(c, resources, binding.file, args[position], depth, binding.outer);
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
    if (depth >= 16) return false;
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
        .identifier => return nameViewed(c, resources, file, node, next, bound),
        .@"switch", .switch_comma => {
            const full = tree.fullSwitch(node).?;
            for (full.ast.cases) |case| if (!try viewed(c, resources, file, tree.fullSwitchCase(case).?.ast.target_expr, next, bound)) return false;
            return true;
        },
        // `@as(T, v)` is `v`.
        .builtin_call_two, .builtin_call_two_comma => {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 2 or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@as")) return false;
            return viewed(c, resources, file, args[1], next, bound);
        },
        // A labeled block holds what each `break` to it gives.
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            const lbrace = tree.nodeMainToken(node);
            if (lbrace < 2 or tree.tokenTag(lbrace - 1) != .colon) return false;
            var any = false;
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                if (tag != .@"break") continue;
                const jump: Ast.Node.Index = @fromBackingInt(@intCast(i));
                const label, const value = tree.nodeData(jump).opt_token_and_opt_node;
                if (breakTarget(tree, model, jump, label.unwrap() orelse continue) != node) continue;
                if (!try viewed(c, resources, file, value.unwrap() orelse return false, next, bound)) return false;
                any = true;
            }
            return any;
        },
        else => {
            if (tree.fullIf(node)) |branch| {
                const otherwise = branch.ast.else_expr.unwrap() orelse return false;
                return try viewed(c, resources, file, branch.ast.then_expr, next, bound) and try viewed(c, resources, file, otherwise, next, bound);
            }
            if (try Facts.calls.at(c.facts, file, node)) |call| return callViewed(c, resources, file, &call, next, bound);
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

/// What a name holds is a view: `null`, a parameter that is one (or what a call passes it,
/// `Binding`), a capture of one, a declared constant, or a local constant made from one.
fn nameViewed(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, node: Ast.Node.Index, next: u8, bound: ?*const Binding) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "null")) return true;
    const reference = model.reference(node) orelse return false;
    const d = reference.declaration orelse return false;
    const record = model.declarations[@backingInt(d)];
    // A parameter is a view in its own function; read through a call (`Binding`), it is
    // what that call passes. One that points (`s: *Scratch`, a method's receiver) reaches
    // memory its caller holds, whatever the call passes: what is read through it stays there.
    if (record.kind == .parameter) {
        if (try c.facts.resolve(file, node) == .pointer) return true;
        return argumentViewed(c, resources, file, record, next, bound);
    }
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
}

/// What a call returns is a view: an `own.Lent`'s `get()`, the program's function whose every
/// return is one, or std's handles to the process's own streams and directory.
fn callViewed(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, call: *const Facts.calls.Call, next: u8, bound: ?*const Binding) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const args = switch (call.args) {
        .known => |args| args,
        .unknown => return false,
    };
    // An `own.Lent`'s `get()`: a copy its owner lends.
    if (call.receiver == .bound and args.len == 1 and tree.nodeTag(call.callee_expr) == .field_access) {
        const method = tree.nodeData(call.callee_expr).node_and_token[1];
        if (std.mem.eql(u8, tree.tokenSlice(method), "get") and try c.role(Contract.library, try c.facts.resolve(file, call.receiver.bound)) == .lent) return true;
    }
    // One that does not resolve is no view: what it gives is judged an owner. Of a choice, each
    // must give one.
    const choices: []const Facts.Decl = switch (call.callee) {
        .function => |*one| one[0..1],
        .choice => |each| each,
        .any => return false,
    };
    for (choices) |choice| {
        if (!try calleeViewed(c, resources, file, call, (try originKnown(c, choice)) orelse return false, args.len, next, bound)) return false;
    }
    return true;
}

/// Whether the function `callee` declares its result `noreturn`: a call of it gives no value.
fn neverReturns(c: *Context, callee: Facts.Decl) Context.Error!bool {
    const target = &c.project.at(callee.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = target.fullFnProto(&buffer, c.project.at(callee.file).model.declarations[@backingInt(callee.index)].node) orelse return false;
    const result = proto.ast.return_type.unwrap() orelse return false;
    return switch (try c.facts.resolve(callee.file, result)) {
        .primitive => |name| std.mem.eql(u8, name, "noreturn"),
        else => false,
    };
}

/// `callViewed` where the call is to `callee`, given `given` arguments.
fn calleeViewed(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, call: *const Facts.calls.Call, callee: Facts.Decl, given: usize, next: u8, bound: ?*const Binding) Context.Error!bool {
    // One that never returns (`aegis.assert.never`, `@panic`'s kind) gives no value, as `unreachable`.
    if (try neverReturns(c, callee)) return true;
    // The program's function whose every return is a view returns one.
    if (try c.facts.program(callee.file)) return views(c, resources, callee, next, &.{ .file = file, .call = call, .callee = callee, .outer = bound });
    if (given != 0) return false;
    for ([_][]const u8{ "Io.File.stdin", "Io.File.stdout", "Io.File.stderr", "Io.Dir.cwd" }) |standard| {
        const decls = switch (try Governed.declarations(c, "std", standard)) {
            .decls => |decls| decls,
            .none, .unknown => continue,
        };
        for (decls) |decl| if (std.meta.eql((try originKnown(c, decl)) orelse continue, callee)) return true;
    }
    return false;
}

/// A021: lock order. A function that holds a guard of an aegis owner (`Guarded`,
/// `BlockingGuarded`, `RwGuarded`, `SpinRwGuarded`, `Order.Ordered`) while it acquires another,
/// or the same one again: two tasks that take two locks in two orders deadlock. The site is the
/// later acquisition, unless both are ranked through one `Order.Context` (`acquireOrdered`,
/// `readOrdered`, `writeOrdered`, their forms), which `Order` checks in Debug; ranked through
/// two contexts, which may be two Orders' that rank nothing against each other, it is
/// undecided, as is a ranked guard a helper gives (its context is the helper's), and one
/// context reset, handed on or made anew each pass (`contextKept`). An acquisition is a call by
/// meaning (Facts.calls): of an owner's acquire however it is named (`@call`, `@field`, an
/// alias), `tryRead` and `tryWrite` among them; of another function whose value is one of the
/// owner's guards (not its `Handoff`); or of a function of the program that returns holding a
/// guard it took, in its value, a member of it, its receiver or a pointer it is given
/// (`leavesHeld`), bound at the call by the local its value or address goes to. A call whose
/// value does not resolve is held as a guard and judged as one: undecided where it is held over
/// another or another over it, known or not. What `@TypeOf` reads is never taken.
///
/// A guard is held from the statement that binds it, a local's declaration or assignment
/// (through `try`, `catch`, `orelse`, a branch, a labeled block's `break`), to its release: a
/// `deinit` or `release` of it, or an `if (g) |*h|` that releases `h`, as a later statement of
/// its block or of one around it up to its declaration's; or such a `defer`, run at its block's
/// exit in the reverse order of the defers there. A guard no statement binds, one used any
/// other way (copied, stored, its address taken) or never so released, is held to the
/// function's end; one held past a loop's pass is held through each pass of that loop, against
/// itself too. A `break` or `continue` between a guard and its release, the release's own
/// statement included, may skip it: held to the end; past a `return` or `try` there, what the
/// defers run on the way out runs holding it. A
/// deferred acquisition runs at its block's exit. One function's own acquisitions only: a call
/// made while holding a guard is not followed.
pub fn lockOrder(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var taken: std.ArrayList(Taken) = .empty;
    for (try Facts.calls.in(c.facts, c.file)) |*call| {
        if (c.inTest(tree.nodeMainToken(call.node)) or !Danger.atRuntime(c, call.node) or typeOnly(tree, model, call.node)) continue;
        const function = enclosingFunction(model, tree, call.node) orelse continue;
        // A call that does not resolve may take a guard: held as one, it is judged as one.
        const lock: Lock, const maybe: ?Facts.Unknown = switch (try acquisitionOf(c, c.file, call, 0)) {
            .no => continue,
            .unknown => |why| .{ .{ .ranked = false }, why },
            .lock => |lock| .{ lock, null },
        };
        try taken.append(c.allocator, .{
            .node = call.node,
            .function = function,
            .lock = lock,
            .maybe = maybe,
            .at = try timeOf(c, tree, model, tree.nodeMainToken(call.node), call.node),
            .held = try heldSpan(c, tree, model, function, call.node, lock.through),
        });
    }
    for (taken.items) |second| for (taken.items) |first| {
        if (first.function != second.function or !first.held.holds(second.at)) continue;
        // One that may be no guard decides nothing: two such never clear each other.
        if (first.maybe orelse second.maybe) |why| {
            try c.unknown(rule, second.node, why);
            break;
        }
        if (first.lock.ranked and second.lock.ranked) {
            if (first.lock.context != null and first.lock.context == second.lock.context and try contextKept(c, c.file, first.function, first.lock.context.?, first.at, second.at, 0)) continue;
            try c.undecided(rule, tree.tokenStart(tree.firstToken(second.node)), .unresolved, "two locks ranked through two contexts: one Order's checks them, two Orders' may take them in two orders");
            break;
        }
        try c.at(rule, tree.firstToken(second.node), "a second lock taken while a guard is held, not both ranked: two tasks taking them in two orders deadlock; aegis Order ranks them and checks the order in Debug");
        break;
    };
}

/// An acquisition A021 judges: the call, its function, the lock, when it runs and how long its
/// guard is held.
const Taken = struct { node: Ast.Node.Index, function: Ast.Node.Index, lock: Lock, maybe: ?Facts.Unknown = null, at: Time, held: Held };

/// A lock an acquisition takes: whether an Order ranks it, the local or parameter that is its
/// `Order.Context`, where one names it, and whether a function of the program took it and
/// returned holding it (`leavesHeld`), its guard in what the call gives or where it writes.
const Lock = struct { ranked: bool, context: ?Model.Declaration.Id = null, through: bool = false, context_from: ?usize = null };

/// Whether the context `decl` holds one value within `function` from `from` (its start, where
/// null) until `until`, the ranked acquisitions taken through it aside: each reference to it in
/// `function` is the context argument (`ctx`, `&ctx`) of a ranked acquisition through it, so
/// nothing there resets it (`ctx = .{}`) or hands it on, and it is declared in no loop, whose
/// passes would each make a new one. A parameter's context (the caller's memory) or one outside
/// any function may be written by another name too: through another pointer or by what a call
/// runs. Where it is such, nothing between `from` and `until` stores through a pointer or into
/// a place outside any function (Facts.accesses' stores and their whole or byte writes through
/// a pointer), and each call there is a ranked acquisition through it, aegis's, or std's given
/// no pointer (`givenPointer`).
fn contextKept(c: *Context, file: Project.FileId, function: Ast.Node.Index, decl: Model.Declaration.Id, from: ?Time, until: Time, depth: u8) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const record = model.declarations[@backingInt(decl)];
    var up = record.node;
    while (model.parentOf(up)) |parent| : (up = parent) {
        if (parent == function) break;
        if (tree.fullWhile(parent) != null or tree.fullFor(parent) != null) return false;
    }
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    for (model.references) |reference| {
        if (reference.declaration != decl or reference.token < first or reference.token > last) continue;
        var at = reference.node;
        while (model.parentOf(at)) |parent| : (at = parent) {
            if (tree.nodeTag(parent) != .address_of and tree.nodeTag(parent) != .grouped_expression) break;
        }
        const call = (try Facts.calls.at(c.facts, file, model.parentOf(at) orelse return false)) orelse return false;
        if (!try rankedThrough(c, file, &call, decl, depth)) return false;
    }
    const container_level = Facts.accesses.global(c.facts, .{ .file = file, .index = decl });
    if (record.kind != .parameter and !container_level) return true;
    for (try Facts.calls.in(c.facts, file)) |*call| {
        if (!try between(c, file, function, call.node, from, until)) continue;
        if (try rankedThrough(c, file, call, decl, depth) or !try mayWrite(c, file, call)) continue;
        return false;
    }
    const index = try Facts.accesses.writesOf(c.facts, file);
    for (index.stores.items) |site| {
        if (!try between(c, file, function, site.node, from, until)) continue;
        if (site.through) return false;
        switch ((try Facts.accesses.pathOf(c.facts, file, site.target orelse site.node)).root) {
            .decl => |root| if (Facts.accesses.global(c.facts, root)) return false,
            .none, .unknown => return false,
        }
    }
    var whole = index.through.keyIterator();
    while (whole.next()) |node| if (try between(c, file, function, node.*, from, until)) return false;
    return true;
}

/// Whether `node` runs within `function` after `from` (its start, where null) and before `until`.
fn between(c: *Context, file: Project.FileId, function: Ast.Node.Index, node: Ast.Node.Index, from: ?Time, until: Time) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    if (enclosingFunction(model, tree, node) != function) return false;
    const at = try timeOf(c, tree, model, tree.firstToken(node), node);
    if (from) |start| if (!start.before(at)) return false;
    return at.before(until);
}

/// Whether a call is a ranked acquisition through the context `decl` (`acquisitionOf`).
fn rankedThrough(c: *Context, file: Project.FileId, call: *const Facts.calls.Call, decl: Model.Declaration.Id, depth: u8) Context.Error!bool {
    return switch (try acquisitionOf(c, file, call, depth)) {
        .lock => |lock| lock.ranked and lock.context == decl,
        .no, .unknown => false,
    };
}

/// Whether a call may write memory the caller names otherwise: each function it may call is
/// neither aegis's, whose owners keep their contexts, nor std's given no pointer.
fn mayWrite(c: *Context, file: Project.FileId, call: *const Facts.calls.Call) Context.Error!bool {
    const each: []const Facts.Decl = switch (call.callee) {
        .function => |*one| one[0..1],
        .choice => |all| all,
        .any => return true,
    };
    const program = try Program.get(c);
    for (each) |choice| {
        const decl = (try originKnown(c, choice)) orelse return true;
        if (try c.inLibrary(Contract.library, decl.file)) continue;
        if (program.std_files.contains(@backingInt(decl.file)) and !try givenPointer(c, file, call)) continue;
        return true;
    }
    return false;
}

/// When code runs within its function, compared in order: for each `defer` it is under,
/// outermost first, its block's exit and then the reverse of the order the defers there are
/// written in; then its own token.
const Time = struct {
    levels: []const Level,

    const Level = struct { at: Ast.TokenIndex, order: u32 };

    fn before(a: Time, b: Time) bool {
        for (a.levels, 0..) |level, i| {
            if (i == b.levels.len) return false;
            const other = b.levels[i];
            if (level.at != other.at) return level.at < other.at;
            if (level.order != other.order) return level.order < other.order;
        }
        return false;
    }

    fn deferred(time: Time) bool {
        return time.levels.len > 1;
    }
};

/// How long a guard is held: after `start` and before `end`; what a defer runs, before `exit`,
/// which a `return` or `try` between the guard and its release leaves at the function's end.
const Held = struct {
    start: Time,
    end: Time,
    exit: Time,

    fn holds(held: Held, at: Time) bool {
        return held.start.before(at) and at.before(if (at.deferred()) held.exit else held.end);
    }
};

/// When the code at `token`, within `node`, runs (`Time`).
fn timeOf(c: *Context, tree: *const Ast, model: *const Model, token: Ast.TokenIndex, node: Ast.Node.Index) Context.Error!Time {
    var levels: std.ArrayList(Time.Level) = .empty;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .@"defer", .@"errdefer" => {
                const block = model.parentOf(parent) orelse break;
                try levels.insert(c.allocator, 0, .{ .at = tree.lastToken(block), .order = std.math.maxInt(u32) - tree.firstToken(parent) });
            },
            .fn_decl => break,
            else => {},
        }
    }
    try levels.append(c.allocator, .{ .at = token, .order = 0 });
    return .{ .levels = levels.items };
}

/// How long the guard the acquisition `node` gives is held (`lockOrder`).
fn heldSpan(c: *Context, tree: *const Ast, model: *const Model, function: Ast.Node.Index, node: Ast.Node.Index, through: bool) Context.Error!Held {
    const body = tree.nodeData(function).node_and_node[1];
    const last: Time = .{ .levels = try c.allocator.dupe(Time.Level, &.{.{ .at = tree.lastToken(body) + 1, .order = 0 }}) };
    const bound = if (through) try throughBound(c, c.file, node) else boundBy(tree, model, node);
    const found = if (bound.declaration != null) try releaseOf(c, c.file, bound) else null;
    const release = found orelse {
        // Held to the end: through each pass of every loop around it.
        const from = outermostLoop(tree, model, bound.statement, function);
        const start = if (from) |loop| try timeOf(c, tree, model, tree.firstToken(loop), loop) else try timeOf(c, tree, model, tree.lastToken(bound.from), bound.from);
        return .{ .start = start, .end = last, .exit = last };
    };
    const start = if (release.loop) |loop| try timeOf(c, tree, model, tree.firstToken(loop), loop) else try timeOf(c, tree, model, tree.lastToken(bound.from), bound.from);
    const end = try timeOf(c, tree, model, tree.firstToken(release.call), release.call);
    // What runs between the guard and a release written after it may leave without it: from
    // the acquisition's value on, within the statement that binds it too (`g, n = .{ a.acquire(),
    // try r.takeByte() }`), up to the release's end, its arguments and the statement that holds
    // it among them (`{ if (x) continue; g.deinit(try io()); }`), or to a `defer`, which runs
    // on every way out after it.
    var exits = false;
    if (tree.firstToken(release.statement) > tree.lastToken(bound.statement)) {
        const until = if (tree.nodeTag(release.statement) == .@"defer") tree.firstToken(release.statement) else tree.lastToken(release.call);
        for (tree.lastToken(bound.value) + 1..until) |token| switch (tree.tokenTag(@intCast(token))) {
            .keyword_break, .keyword_continue => {
                const from = outermostLoop(tree, model, bound.statement, function);
                return .{ .start = if (from) |loop| try timeOf(c, tree, model, tree.firstToken(loop), loop) else start, .end = last, .exit = last };
            },
            .keyword_return, .keyword_try => exits = true,
            else => {},
        };
    }
    return .{ .start = start, .end = end, .exit = if (exits) last else end };
}

/// The outermost loop around `node` within `function`.
fn outermostLoop(tree: *const Ast, model: *const Model, node: Ast.Node.Index, function: Ast.Node.Index) ?Ast.Node.Index {
    var found: ?Ast.Node.Index = null;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (parent == function) break;
        if (tree.fullWhile(parent) != null or tree.fullFor(parent) != null) found = parent;
    }
    return found;
}

/// A guard's binding (`boundBy`): the statement, the local, and the member of it that holds the
/// guard where a record literal's field does; the node after which it is held: the statement,
/// or the acquisition where a literal holds others made after it; and the acquisition's value as
/// the statement takes it (through `try`, `catch`, `orelse`, a branch), after which what the
/// statement runs runs with the guard held.
const Bound = struct { statement: Ast.Node.Index, declaration: ?Model.Declaration.Id, member: ?[]const u8 = null, from: Ast.Node.Index, value: Ast.Node.Index, any_member: bool = false };

/// Whether what a call gives holds a pointer to what may hold a guard (`guardHeld`), or one that
/// does not resolve: `take()` returning `&h.guard`.
fn pointsAtGuard(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    for (try c.facts.heldParts(c.allocator, try c.facts.resolve(file, node))) |part| switch (part) {
        .pointer => |to| if (try guardHeld(c, to.child.*) != .no) return true,
        else => {},
    };
    return false;
}

/// The binding of a guard a function of the program took and returned holding (`leavesHeld`):
/// the local the call's value binds where that value may hold a guard or point at one
/// (`guardValue`, `pointsAtGuard`), the guard in it or in one of its members (`held.guard.deinit()`); else the local whose address the
/// call is given (`lockInto(a, &g)`).
fn throughBound(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!Bound {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var bound = boundBy(tree, model, node);
    if (bound.declaration != null and (try guardValue(c, file, node) != .no or try pointsAtGuard(c, file, node))) {
        if (bound.member == null) bound.any_member = true;
        return bound;
    }
    bound.declaration = null;
    bound.member = null;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return bound;
    var found: ?Model.Declaration.Id = null;
    for (call.ast.params) |param| {
        if (tree.nodeTag(param) != .address_of) continue;
        const local = localOf(tree, model, tree.nodeData(param).node) orelse continue;
        if (found != null) return bound;
        found = local;
    }
    bound.declaration = found orelse return bound;
    bound.any_member = true;
    return bound;
}

/// The statement that binds the guard an acquisition gives, and the local it binds: a
/// declaration's or an assignment's, its value reached through `try`, `catch`'s and `orelse`'s
/// left side, parentheses, a branch's value and a labeled block's `break`; a record literal's
/// field (`.{ .guard = l.acquire() }`, the local's member) and a tuple's element a destructure
/// takes apart (`g, n = .{ l.acquire(), 1 }`) among them. Bound by no statement, the
/// acquisition is its own.
fn boundBy(tree: *const Ast, model: *const Model, node: Ast.Node.Index) Bound {
    const unbound: Bound = .{ .statement = node, .declaration = null, .from = node, .value = node };
    var at = node;
    while (model.parentOf(at)) |parent| {
        const next: ?Ast.Node.Index = switch (tree.nodeTag(parent)) {
            .@"try", .grouped_expression => parent,
            .@"catch", .@"orelse" => if (tree.nodeData(parent).node_and_node[0] == at) parent else null,
            .@"break" => labeled(tree, model, parent),
            else => if (tree.fullIf(parent)) |branch| (if (branch.ast.cond_expr != at) parent else null) else if (tree.fullSwitchCase(parent)) |case| (if (case.ast.target_expr == at) parent else null) else if (tree.fullSwitch(parent)) |choice| (if (choice.ast.condition != at) parent else null) else null,
        };
        at = next orelse break;
    }
    const taken_as = at;
    var parent = model.parentOf(at) orelse return unbound;
    var member: ?[]const u8 = null;
    var from: ?Ast.Node.Index = null;
    var fields: [2]Ast.Node.Index = undefined;
    var elements: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&fields, parent)) |record| {
        if (std.mem.findScalar(Ast.Node.Index, record.ast.fields, at) == null) return unbound;
        // `.name = value`: the name two tokens before the value.
        member = tree.tokenSlice(tree.firstToken(at) - 2);
        from = node;
        at = parent;
        parent = model.parentOf(at) orelse return unbound;
    } else if (tree.fullArrayInit(&elements, parent)) |tuple| {
        const position = std.mem.findScalar(Ast.Node.Index, tuple.ast.elements, at) orelse return unbound;
        const statement = model.parentOf(parent) orelse return unbound;
        if (tree.nodeTag(statement) != .assign_destructure) return unbound;
        const full = tree.assignDestructure(statement);
        if (full.ast.value_expr != parent or position >= full.ast.variables.len) return unbound;
        return .{ .statement = statement, .declaration = localOf(tree, model, full.ast.variables[position]) orelse return unbound, .from = node, .value = taken_as };
    }
    if (tree.fullVarDecl(parent)) |variable| {
        if (variable.ast.init_node.unwrap() != at) return unbound;
        return .{ .statement = parent, .declaration = localOf(tree, model, parent) orelse return unbound, .member = member, .from = from orelse parent, .value = taken_as };
    }
    if (tree.nodeTag(parent) != .assign) return unbound;
    const target, const value = tree.nodeData(parent).node_and_node;
    if (value != at) return unbound;
    return .{ .statement = parent, .declaration = localOf(tree, model, target) orelse return unbound, .member = member, .from = from orelse parent, .value = taken_as };
}

/// The local variable `node` declares (`var g = ...`, a destructure's `var g`) or names (`g`).
fn localOf(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Model.Declaration.Id {
    if (tree.fullVarDecl(node) != null) {
        for (model.declarations, 0..) |record, i| {
            if (record.kind == .variable and record.node == node) return @fromBackingInt(@intCast(i));
        }
        return null;
    }
    if (tree.nodeTag(node) != .identifier) return null;
    const d = (model.reference(node) orelse return null).declaration orelse return null;
    return if (model.declarations[@backingInt(d)].kind == .variable) d else null;
}

/// The labeled block a `break :label value` leaves with its value; null for a plain `break`,
/// one that leaves a loop, and one with no value.
fn labeled(tree: *const Ast, model: *const Model, jump: Ast.Node.Index) ?Ast.Node.Index {
    const label, const value = tree.nodeData(jump).opt_token_and_opt_node;
    const name = tree.tokenSlice(label.unwrap() orelse return null);
    _ = value.unwrap() orelse return null;
    var at = jump;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                const brace = tree.nodeMainToken(parent);
                if (brace < 2 or tree.tokenTag(brace - 1) != .colon) continue;
                if (std.mem.eql(u8, tree.tokenSlice(brace - 2), name)) return parent;
            },
            .fn_decl => return null,
            else => if (tree.fullWhile(parent) != null or tree.fullFor(parent) != null) {
                const keyword = tree.firstToken(parent);
                if (keyword >= 2 and tree.tokenTag(keyword - 1) == .colon and std.mem.eql(u8, tree.tokenSlice(keyword - 2), name)) return null;
            },
        }
    }
    return null;
}

/// A guard's release (`releaseOf`): its statement, the call, and the outermost loop between
/// the guard and the release, whose next pass the guard outlives.
const Release = struct { statement: Ast.Node.Index, call: Ast.Node.Index, loop: ?Ast.Node.Index };

/// Where the guard `decl` holds from `statement` is released: a later statement that releases
/// it in `statement`'s block or one around it, up to its declaration's, or a `defer` of one
/// there. Null where the guard is used any other way (`onlyHeld`) or no such release is found.
fn releaseOf(c: *Context, file: Project.FileId, bound: Bound) Context.Error!?Release {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const statement = bound.statement;
    const decl = bound.declaration.?; // unreachable: heldSpan asks only of a bound guard.
    if (!onlyHeld(tree, model, decl, statement)) return null;
    const member: Member = if (bound.member) |name| .{ .named = name } else if (bound.any_member) .any else .none;
    const declared = model.declarations[@backingInt(decl)].node;
    var loop: ?Ast.Node.Index = null;
    var at = statement;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.fullWhile(parent) != null or tree.fullFor(parent) != null) loop = parent;
        switch (tree.nodeTag(parent)) {
            .@"defer", .@"errdefer", .fn_decl => return null,
            .block, .block_semicolon, .block_two, .block_two_semicolon => {},
            else => continue,
        }
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, parent) orelse return null;
        const own = std.mem.findScalar(Ast.Node.Index, statements, at) orelse return null;
        for (statements, 0..) |each, i| {
            if (tree.nodeTag(each) == .@"defer") {
                if (try releases(c, file, tree.nodeData(each).node, decl, member)) |call| return .{ .statement = each, .call = call, .loop = loop };
                continue;
            }
            if (i <= own) continue;
            if (try releases(c, file, each, decl, member)) |call| return .{ .statement = each, .call = call, .loop = loop };
        }
        if (std.mem.findScalar(Ast.Node.Index, statements, declared) != null) return null;
    }
    return null;
}

/// Where a local holds the guard: itself, a member named, or itself or any one member.
const Member = union(enum) { none, named: []const u8, any };

/// The call by which `node`, a statement or a `defer`'s expression, releases the guard `decl`:
/// a call (Facts.calls) of a guard's release (`guardRelease`) whose receiver is it (its
/// `member`, where a record holds it), one of a block's statements, or one of what an
/// `if (g) |*h|` with no `else` captures.
fn releases(c: *Context, file: Project.FileId, node: Ast.Node.Index, decl: Model.Declaration.Id, member: Member) Context.Error!?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, node)) |statements| {
        for (statements) |each| if (try releases(c, file, each, decl, member)) |call| return call;
        return null;
    }
    if (tree.fullIf(node)) |branch| {
        if (branch.ast.else_expr != .none or tree.nodeTag(branch.ast.cond_expr) != .identifier) return null;
        const reference = model.reference(branch.ast.cond_expr) orelse return null;
        if (reference.declaration != decl) return null;
        const payload = branch.payload_token orelse return null;
        if (tree.tokenTag(payload) != .asterisk) return null;
        for (model.declarations, 0..) |record, i| {
            if (record.kind != .capture or record.token != payload + 1) continue;
            return releases(c, file, branch.ast.then_expr, @fromBackingInt(@intCast(i)), member);
        }
        return null;
    }
    // A declaration, a store or a return given what the guard is handed on to
    // (`var ga = fa.await(io)`).
    if (tree.fullVarDecl(node)) |variable| return if (variable.ast.init_node.unwrap()) |value| movedBy(c, file, value, decl) else null;
    if (tree.nodeTag(node) == .assign) return movedBy(c, file, tree.nodeData(node).node_and_node[1], decl);
    if (tree.nodeTag(node) == .@"return") return if (tree.nodeData(node).opt_node.unwrap()) |value| movedBy(c, file, value, decl) else null;
    const call = (try Facts.calls.at(c.facts, file, node)) orelse return null;
    if (tree.nodeTag(call.callee_expr) != .field_access) return null;
    var receiver, const method = tree.nodeData(call.callee_expr).node_and_token;
    if (call.receiver == .none) return null;
    if (!try guardRelease(c, call.callee)) {
        // A guard whose type does not resolve, as its acquisition does not, is judged as one:
        // its own `deinit` or `release`, which does not resolve with it, releases it.
        if (call.callee != .any or member == .named or tree.nodeTag(receiver) != .identifier) return null;
        const spelled = tree.tokenSlice(method);
        if (!std.mem.eql(u8, spelled, "deinit") and !std.mem.eql(u8, spelled, "release")) return null;
    }
    switch (member) {
        .none => {},
        .named => |name| {
            if (tree.nodeTag(receiver) != .field_access) return null;
            const holder, const field = tree.nodeData(receiver).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(field), name)) return null;
            receiver = holder;
        },
        .any => if (tree.nodeTag(receiver) == .field_access) {
            receiver = tree.nodeData(receiver).node_and_token[0];
        },
    }
    if (tree.nodeTag(receiver) != .identifier) return null;
    const reference = model.reference(receiver) orelse return null;
    return if (reference.declaration == decl) node else null;
}

/// The call `value` is, through `try`, that hands on the guard `decl` holds into its value
/// (`handedOn`), which binds it anew.
fn movedBy(c: *Context, file: Project.FileId, value: Ast.Node.Index, decl: Model.Declaration.Id) Context.Error!?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = Facts.ungrouped(tree, value);
    while (tree.nodeTag(at) == .@"try") at = Facts.ungrouped(tree, tree.nodeData(at).node);
    const call = (try Facts.calls.at(c.facts, file, at)) orelse return null;
    if (!try handedOn(c, file, &call)) return null;
    const holder = Facts.ungrouped(tree, call.receiver.bound);
    if (tree.nodeTag(holder) != .identifier) return null;
    const reference = model.reference(holder) orelse return null;
    return if (reference.declaration == decl) at else null;
}

/// Whether a call hands the guard its receiver holds on into its value, which takes it from
/// there (`acquisitionOf`): std's Io.Future's `await` or `cancel`, each of which gives the one
/// result the future holds (`io.async(L.acquire, .{a})`).
fn handedOn(c: *Context, file: Project.FileId, call: *const Facts.calls.Call) Context.Error!bool {
    const holder = switch (call.receiver) {
        .bound => |node| node,
        .none, .unknown => return false,
    };
    const each: []const Facts.Decl = switch (call.callee) {
        .function => |*one| one[0..1],
        .choice => |all| all,
        .any => return false,
    };
    for (each) |choice| {
        const name = c.project.at(choice.file).model.declarations[@backingInt(choice.index)].name;
        if (!std.mem.eql(u8, name, "await") and !std.mem.eql(u8, name, "cancel")) return false;
    }
    const value = switch (try c.facts.resolve(file, holder)) {
        .pointer => |inner| inner.child.*,
        else => |other| other,
    };
    const made = switch (value) {
        .instance, .container => |found| found.made_by orelse return false,
        else => return false,
    };
    return try Governed.isStd(c, made.function, "Io.Future") == .yes;
}

/// Whether a callee is a guard's release, each it may be: a `deinit` or `release` a guard's
/// type declares (`guardType`). One that does not resolve releases nothing known.
fn guardRelease(c: *Context, callee: Facts.calls.Callee) Context.Error!bool {
    const each: []const Facts.Decl = switch (callee) {
        .function => |*one| one[0..1],
        .choice => |all| all,
        .any => return false,
    };
    for (each) |choice| {
        const decl = (try originKnown(c, choice)) orelse return false;
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        if (record.kind != .function or !(std.mem.eql(u8, record.name, "deinit") or std.mem.eql(u8, record.name, "release"))) return false;
        switch (try guardType(c, .{ .file = decl.file, .scope = record.scope })) {
            .plain, .ranked => {},
            .no, .unknown => return false,
        }
    }
    return true;
}

/// Whether the guard local `decl` is only held: each use of it a member's (`g.value()`,
/// `g.deinit()`), the statement that binds it, or an `if (g) |*h|`, which copies
/// nothing. A copy, a store, its address taken may keep it past its release.
fn onlyHeld(tree: *const Ast, model: *const Model, decl: Model.Declaration.Id, statement: Ast.Node.Index) bool {
    for (model.references) |reference| {
        if (reference.declaration != decl) continue;
        const parent = model.parentOf(reference.node) orelse return false;
        if (parent == statement) continue;
        // Its address given to the call that binds it (`lockInto(a, &g)`).
        if (tree.nodeTag(parent) == .address_of and reference.token >= tree.firstToken(statement) and reference.token <= tree.lastToken(statement)) continue;
        if (tree.nodeTag(parent) == .field_access and tree.nodeData(parent).node_and_token[0] == reference.node) continue;
        if (tree.fullIf(parent)) |branch| {
            if (branch.ast.cond_expr == reference.node) if (branch.payload_token) |payload| if (tree.tokenTag(payload) == .asterisk) continue;
        }
        return false;
    }
    return true;
}

/// Whether `node` is read by `@TypeOf`, which never runs it.
fn typeOnly(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parent)), "@TypeOf")) return true,
            .fn_decl => return false,
            else => {},
        }
    }
    return false;
}

/// What a call takes (`lockOrder`): no lock, one, or what does not resolve.
const Acquisition = union(enum) { no, lock: Lock, unknown: Facts.Unknown };

/// Whether a call acquires a lock: a callee that is an aegis owner's acquire, by its
/// declaration; a function of the program with a body, by that body (`leavesHeld`: it returns
/// holding a guard it took, however it hands the guard back); std's other functions take none;
/// another of the owner's methods, or another function outside the program, whose value is a
/// guard (`guardValue`). One that does not resolve takes none where its value is known no guard
/// and it is given no guard's address (`guardGiven`). Of a choice, any.
fn acquisitionOf(c: *Context, file: Project.FileId, call: *const Facts.calls.Call, depth: u8) Context.Error!Acquisition {
    // A call made a statement gives nothing (Zig refuses to drop a value that is not void):
    // it takes a guard only where it leaves one held through a pointer or its receiver.
    const statement = discarded(&c.project.at(file).file.tree, &c.project.at(file).model, call.node);
    const choices: []const Facts.Decl = switch (call.callee) {
        .function => |*one| one[0..1],
        .choice => |all| all,
        .any => &.{},
    };
    var lock: ?Lock = null;
    var unknown: ?Facts.Unknown = null;
    var other = choices.len == 0;
    const program = try Program.get(c);
    for (choices) |choice| {
        const decl = (try originKnown(c, choice)) orelse {
            other = true;
            continue;
        };
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        const owner: Facts.Value = .{ .container = .{ .file = decl.file, .scope = record.scope } };
        if (record.kind == .function and try c.role(Contract.library, owner) == .guarded and Contract.acquisition(record.name)) {
            const ranked = std.mem.find(u8, record.name, "Ordered") != null;
            // Of a choice, ranked only where each is; read before `lock` is written.
            const found: Lock = .{ .ranked = ranked and (if (lock) |earlier| earlier.ranked else true), .context = if (ranked) contextOf(c, file, call) else null };
            lock = found;
            continue;
        }
        // std's, by its value alone (`Future(Guard).await` gives one).
        if (program.std_files.contains(@backingInt(decl.file))) {
            other = true;
            continue;
        }
        // One of the program's with a body is read by its body alone.
        const body = record.kind == .function and program.own(decl.file) and if (c.project.at(decl.file).model.parentOf(record.node)) |parent| c.project.at(decl.file).file.tree.nodeTag(parent) == .fn_decl else false;
        if (!body) other = true;
        if (record.kind != .function) continue;
        switch (try leavesHeld(c, decl, depth)) {
            .no => {},
            .unknown => |why| unknown = why,
            .lock => |inner| {
                // Ranked through its parameter's context: the caller's argument there.
                const context = if (inner.context_from) |position| argumentContext(c, file, call, position) else null;
                const found: Lock = .{ .ranked = inner.ranked and (if (lock) |earlier| earlier.ranked else true), .through = true, .context = context };
                lock = found;
            },
        }
    }
    if (lock) |found| if (found.through) return .{ .lock = found };
    // One given a pointer (`lockInto(a, &g)`) may write a guard there all the same.
    if (statement and !try givenPointer(c, file, call)) return .no;
    if (!other) return if (lock) |found| .{ .lock = found } else .no;
    // A guard in what the call gives is bound as a helper's is (`throughBound`): the local its
    // value binds, the guard in it or in one of its members.
    return switch (try guardValue(c, file, call.node)) {
        .plain => .{ .lock = .{ .ranked = false, .through = true } },
        // A helper's ranked guard was ranked through a context of its own, which its arguments
        // need not name: no context is known.
        .ranked => .{ .lock = .{ .ranked = if (lock) |earlier| earlier.ranked else true, .through = true } },
        .no => if (lock) |found| .{ .lock = found } else if (unknown) |why| .{ .unknown = why } else if (call.callee == .any) try guardGiven(c, file, call) else .no,
        .unknown => |why| if (lock) |found| .{ .lock = found } else .{ .unknown = why },
    };
}

/// Whether a call is given a pointer (Facts.calls' arguments, its receiver among them): one an
/// argument holds by value (`&g`, `p` of `const p = &g`, `.{ .slot = &g }`), or an argument
/// that does not resolve, which may be one. Where a receiver that does not resolve leaves
/// Facts.calls' arguments unknown, the arguments as written (a receiver, bound or not, is no
/// address the call is given).
fn givenPointer(c: *Context, file: Project.FileId, call: *const Facts.calls.Call) Context.Error!bool {
    var buffer: [1]Ast.Node.Index = undefined;
    const args = switch (call.args) {
        .known => |args| args,
        .unknown => if (call.receiver == .unknown) (c.project.at(file).file.tree.fullCall(&buffer, call.node) orelse return true).ast.params else return true,
    };
    for (args) |arg| for (try c.facts.heldParts(c.allocator, try c.facts.resolve(file, arg))) |part| switch (part) {
        .pointer, .unknown => return true,
        else => {},
    };
    return false;
}

/// Whether a call that does not resolve, whose value is no guard, may take one all the same
/// into what it is given (Facts.calls' arguments, its receiver among them): through a pointer
/// an argument holds by value (`givenPointer`) to what holds a guard or does not resolve, or
/// an argument that does not resolve.
fn guardGiven(c: *Context, file: Project.FileId, call: *const Facts.calls.Call) Context.Error!Acquisition {
    const args = switch (call.args) {
        .known => |args| args,
        .unknown => |why| return .{ .unknown = why },
    };
    for (args) |arg| for (try c.facts.heldParts(c.allocator, try c.facts.resolve(file, arg))) |part| switch (part) {
        .pointer => |to| switch (try guardHeld(c, to.child.*)) {
            .no => {},
            .unknown => |why| return .{ .unknown = why },
            .plain, .ranked => return .{ .unknown = .unresolved },
        },
        .unknown => |why| return .{ .unknown = why },
        else => {},
    };
    return .no;
}

/// Whether a function of the program returns holding a guard it took: one bound by no local or
/// by one no release reaches (returned, stored, written through a pointer or into its
/// receiver), through the functions it calls in turn; one that does not resolve, held so, may.
fn leavesHeld(c: *Context, decl: Facts.Decl, depth: u8) Context.Error!Acquisition {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    if (depth == 8) return .{ .unknown = .cycle };
    const program = try Program.get(c);
    if (!program.own(decl.file)) return .no;
    const tree = &c.project.at(decl.file).file.tree;
    const model = &c.project.at(decl.file).model;
    const function = model.parentOf(model.declarations[@backingInt(decl.index)].node) orelse return .no;
    if (tree.nodeTag(function) != .fn_decl) return .no;
    const memo = try c.facts.memo(HeldBy);
    if (memo.map.get(decl)) |known| {
        if (known) |found| return found;
        // A function that reaches itself adds no guard it does not take itself; one read
        // while another is being read is not kept, as that one may yet hold one.
        memo.back = true;
        return .no;
    }
    try memo.map.put(c.allocator, decl, null);
    const outer = memo.back;
    memo.back = false;
    const out = try heldAtExit(c, tree, model, function, decl.file, depth);
    if (memo.back) {
        _ = memo.map.remove(decl);
    } else try memo.map.put(c.allocator, decl, out);
    memo.back = outer or memo.back;
    return out;
}

/// `leavesHeld`'s answers, null while one is being read, and whether a read met one being read.
const HeldBy = struct { map: std.AutoHashMapUnmanaged(Facts.Decl, ?Acquisition) = .empty, back: bool = false };

/// Whether `function` returns holding a guard it took (`leavesHeld`).
fn heldAtExit(c: *Context, tree: *const Ast, model: *const Model, function: Ast.Node.Index, file: Project.FileId, depth: u8) Context.Error!Acquisition {
    var out: Acquisition = .no;
    for (try Facts.calls.in(c.facts, file)) |*call| {
        if (enclosingFunction(model, tree, call.node) != function or typeOnly(tree, model, call.node)) continue;
        const found = try acquisitionOf(c, file, call, depth + 1);
        if (found == .no) continue;
        const bound = if (found == .lock and found.lock.through) try throughBound(c, file, call.node) else boundBy(tree, model, call.node);
        if (bound.declaration != null and try releaseOf(c, file, bound) != null) continue;
        switch (found) {
            .no => unreachable, // unreachable: skipped above.
            .lock => |lock| {
                // Ranked through its parameter's context, kept as the caller gives it up to here.
                const position = if (lock.context) |d| parameterPosition(tree, model, function, d) else null;
                const unwritten = if (position != null) try contextKept(c, file, function, lock.context.?, null, try timeOf(c, tree, model, tree.firstToken(call.node), call.node), depth + 1) else false;
                return .{ .lock = .{ .ranked = lock.ranked, .context_from = if (unwritten) position else null } };
            },
            .unknown => |why| out = .{ .unknown = why },
        }
    }
    return out;
}

/// Whether the call `node` is a statement, through `try` and parentheses, or a `defer`'s.
fn discarded(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) switch (tree.nodeTag(parent)) {
        .@"try", .grouped_expression => {},
        .@"defer", .@"errdefer" => return true,
        else => {
            var buffer: [2]Ast.Node.Index = undefined;
            return tree.blockStatements(&buffer, parent) != null;
        },
    };
    return false;
}

/// The position among `function`'s parameters of the parameter `decl`, where it is one.
fn parameterPosition(tree: *const Ast, model: *const Model, function: Ast.Node.Index, decl: Model.Declaration.Id) ?usize {
    const record = model.declarations[@backingInt(decl)];
    if (record.kind != .parameter) return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]) orelse return null;
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) if (param.name_token == record.token) return position;
    return null;
}

/// The local or parameter a call's argument at `position` names, `&` or not: the context a
/// helper ranks through where it is its parameter there.
fn argumentContext(c: *Context, file: Project.FileId, call: *const Facts.calls.Call, position: usize) ?Model.Declaration.Id {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const args = switch (call.args) {
        .known => |args| args,
        .unknown => return null,
    };
    if (position >= args.len) return null;
    var at = args[position];
    while (tree.nodeTag(at) == .address_of or tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node;
    if (tree.nodeTag(at) != .identifier) return null;
    return (model.reference(at) orelse return null).declaration;
}

/// The local or parameter a ranked acquisition's `Order.Context` argument names, `&` or not.
fn contextOf(c: *Context, file: Project.FileId, call: *const Facts.calls.Call) ?Model.Declaration.Id {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const args = switch (call.args) {
        .known => |args| args,
        .unknown => return null,
    };
    // The receiver, the Io, the context.
    if (args.len != 3) return null;
    var at = args[2];
    while (tree.nodeTag(at) == .address_of or tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node;
    if (tree.nodeTag(at) != .identifier) return null;
    return (model.reference(at) orelse return null).declaration;
}

/// Whether a value is a guard (`guardValue`), and an Order's ranked one.
const Guard = union(enum) { no, plain, ranked, unknown: Facts.Unknown };

/// Whether what a call gives holds a guard by value (`guardHeld`). One that does not resolve
/// is a guard where its declared result names one.
fn guardValue(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!Guard {
    return switch (try guardHeld(c, try c.facts.resolve(file, node))) {
        .unknown => |why| if (try Contract.kind(c, file, node, 0) != .guard) .{ .unknown = why } else if (rankedForm(&c.project.at(file).file.tree, node)) .ranked else .plain,
        else => |found| found,
    };
}

/// Whether a value holds a guard by value (Facts.heldParts: through its error union, optional,
/// array, a choice of types and a record's fields): a type declared in an aegis owner (`Guard`,
/// `ReadGuard`, `WriteGuard`) or an Order's ranked capability; a part that does not resolve
/// may be one.
fn guardHeld(c: *Context, value: Facts.Value) Context.Error!Guard {
    var guard: Guard = .no;
    for (try c.facts.heldParts(c.allocator, value)) |part| switch (part) {
        .unknown => |why| return .{ .unknown = why },
        .instance, .container => |held| switch (try guardType(c, held)) {
            .no => {},
            // Of a choice, ranked only where each is.
            .plain => guard = .plain,
            .ranked => if (guard == .no) {
                guard = .ranked;
            },
            .unknown => |why| return .{ .unknown = why },
        },
        else => {},
    };
    return guard;
}

/// Whether a call is an owner's ranked acquisition by its form (`acquireOrdered`, `readOrdered`,
/// ...), as AegisContract.kind reads an acquisition whose value does not resolve.
fn rankedForm(tree: *const Ast, node: Ast.Node.Index) bool {
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const name = tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]);
    return Contract.acquisition(name) and std.mem.find(u8, name, "Ordered") != null;
}

/// Whether a container is a guard's: declared within an aegis owner, or an Order's
/// `Capability`.
fn guardType(c: *Context, held: Facts.Container) Context.Error!Guard {
    const model = &c.project.at(held.file).model;
    const tree = &c.project.at(held.file).file.tree;
    var scope = model.scopes[@backingInt(held.scope)].parent;
    while (scope) |s| : (scope = model.scopes[@backingInt(s)].parent) {
        if (model.scopes[@backingInt(s)].kind != .container) continue;
        if (try c.role(Contract.library, .{ .container = .{ .file = held.file, .scope = s } }) != .guarded) continue;
        // Of what an owner declares, its guards (`Guard`, `ReadGuard`, `WriteGuard`); a
        // `Handoff` holds no lock.
        const declared = model.parentOf(model.scopes[@backingInt(held.scope)].node) orelse return .no;
        const variable = tree.fullVarDecl(declared) orelse return .no;
        return if (Contract.guardType(tree.tokenSlice(variable.ast.mut_token + 1))) .plain else .no;
    }
    const orders = switch (try Governed.declarations(c, "aegis", "Order")) {
        .decls => |decls| decls,
        .none => return .no,
        .unknown => |why| return .{ .unknown = why },
    };
    for (orders) |order| {
        const decl = (try originKnown(c, order)) orelse return .{ .unknown = .unresolved };
        if (decl.file != held.file) continue;
        const capability = model.scopes[@backingInt(model.root())].names.get("Capability") orelse continue;
        const function = model.parentOf(model.declarations[@backingInt(capability)].node) orelse continue;
        const first = model.scopes[@backingInt(held.scope)].first;
        if (first >= tree.firstToken(function) and first <= tree.lastToken(function)) return .ranked;
    }
    return .no;
}

/// A016: two or more identifying integers of one type meeting in one public signature or one
/// public struct, where nothing keeps one from standing for the other. A signature is a
/// function's or a function type's (`*const fn (parent_id: u32, child_id: u32) void`), and a
/// struct any container `reached` from outside the file: by a `pub` name, a name a reached
/// declaration uses (`pub const Link = Edge;`), a public signature's (an anonymous struct
/// parameter) or what a reached type function returns. Two names are one integer when their
/// types resolve to it, or are spelled the same and are an integer whatever a build chooses
/// (`const Id = if (wide) u64 else u32`); a type that does not resolve, or a choice that may
/// meet the other's, is undecided.
pub fn identity(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const reaches = try reached(c, tree, model);
    for (model.declarations, 0..) |decl, index| {
        if (decl.kind != .function or !(decl.public or reaches[index]) or c.inTest(decl.token)) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, decl.node) orelse continue;
        try signature(c, rule, tree, proto, decl.token);
    }
    for (0..tree.nodes.len) |raw| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        switch (tree.nodeTag(node)) {
            .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => {},
            else => continue,
        }
        const parent = model.parentOf(node) orelse continue;
        if (tree.nodeTag(parent) == .fn_decl or c.inTest(tree.firstToken(node)) or !try reachedFrom(c, tree, model, reaches, node)) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        try signature(c, rule, tree, tree.fullFnProto(&buffer, node) orelse continue, tree.firstToken(node));
    }
    for (model.scopes) |scope| {
        if (scope.kind != .container and scope.kind != .file) continue;
        if (scope.kind == .container and !publicContainer(tree, model, scope.node) and !try reachedFrom(c, tree, model, reaches, scope.node)) continue;
        var names: std.ArrayList(Ast.TokenIndex) = .empty;
        var kinds: std.ArrayList(Kind) = .empty;
        for (model.declarations) |decl| {
            if (decl.kind != .field or decl.scope != scope.id or c.inTest(decl.token) or !identifies(decl.name)) continue;
            const written = (model.containerField(tree, decl.node) orelse continue).ast.type_expr.unwrap() orelse continue;
            const kind = (try kindOf(c, tree, written)) orelse continue;
            try names.append(c.allocator, decl.token);
            try kinds.append(c.allocator, kind);
        }
        const pair = meet(names.items, kinds.items) orelse continue;
        if (pair.same == .maybe) {
            try c.undecided(rule, tree.tokenStart(pair.second), .unresolved, try c.allocator.print("fields '{s}' and '{s}' identify, and their types may be one integer: one may be stored for the other", .{ tree.tokenSlice(pair.first), tree.tokenSlice(pair.second) }));
            continue;
        }
        try c.at(rule, pair.second, try c.allocator.print("fields '{s}' and '{s}' are both {s} that identify: one may be stored for the other; aegis id.Id or a handle gives each its own type", .{ tree.tokenSlice(pair.first), tree.tokenSlice(pair.second), pair.kind }));
    }
}

/// A016 over one signature's parameters, reported at `at`.
fn signature(c: *Context, rule: Rule, tree: *const Ast, proto: Ast.full.FnProto, at: Ast.TokenIndex) Context.Error!void {
    var names: std.ArrayList(Ast.TokenIndex) = .empty;
    var kinds: std.ArrayList(Kind) = .empty;
    var it = proto.iterate(tree);
    while (it.next()) |param| {
        const name = param.name_token orelse continue;
        if (param.comptime_noalias != null or !identifies(tree.tokenSlice(name))) continue;
        // `anytype` is whatever a caller gives, an integer among them.
        const kind: Kind = if (param.type_expr) |written| (try kindOf(c, tree, written)) orelse continue else .{ .spelled = "anytype", .unknown = true };
        try names.append(c.allocator, name);
        try kinds.append(c.allocator, kind);
    }
    const pair = meet(names.items, kinds.items) orelse return;
    if (pair.same == .maybe) return c.undecided(rule, tree.tokenStart(at), .unresolved, try c.allocator.print("'{s}' and '{s}' identify, and their types may be one integer: one may be passed for the other", .{ tree.tokenSlice(pair.first), tree.tokenSlice(pair.second) }));
    try c.at(rule, at, try c.allocator.print("'{s}' and '{s}' are both {s} that identify: one may be passed for the other; aegis id.Id or a handle gives each its own type", .{ tree.tokenSlice(pair.first), tree.tokenSlice(pair.second), pair.kind }));
}

/// What an identifying name's type may be as an integer (`kindOf`): the integers it resolves
/// to, one or a build's choice; whether each choice is one (`all`); whether which one it is
/// does not resolve (`unknown`).
const Kind = struct {
    spelled: []const u8,
    integers: []const []const u8 = &.{},
    all: bool = false,
    unknown: bool = false,
};

/// The integers a type written at `node` may be; null for a type that is none in any build.
fn kindOf(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!?Kind {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    const spelled = tree.source[tree.tokenStart(first) .. tree.tokenStart(last) + tree.tokenSlice(last).len];
    const value = try c.facts.resolve(c.file, node);
    switch (value) {
        .unknown, .reflected => return .{ .spelled = spelled, .unknown = true },
        // `@Int` of a width computed as the program compiles: an integer, which one unread.
        .primitive => |name| return if (std.mem.eql(u8, name, "@Int")) .{ .spelled = spelled, .all = true, .unknown = true } else .{ .spelled = spelled, .integers = try c.allocator.dupe([]const u8, &.{integer(value) orelse return null}), .all = true },
        .alternatives => |each| {
            var integers: std.ArrayList([]const u8) = .empty;
            var computed: usize = 0;
            for (each) |alternative| {
                if (integer(alternative)) |name| try integers.append(c.allocator, name);
                if (alternative == .primitive and std.mem.eql(u8, alternative.primitive, "@Int")) computed += 1;
            }
            if (integers.items.len + computed == 0) return null;
            return .{ .spelled = spelled, .integers = integers.items, .all = integers.items.len + computed == each.len, .unknown = computed != 0 };
        },
        else => return null,
    }
}

/// The first two names that are one integer, or else the first two that may be (`.maybe`).
fn meet(names: []const Ast.TokenIndex, kinds: []const Kind) ?struct { first: Ast.TokenIndex, second: Ast.TokenIndex, kind: []const u8, same: enum { yes, maybe } } {
    var maybe: ?[2]usize = null;
    for (kinds, 0..) |kind, i| for (kinds[0..i], 0..) |earlier, j| switch (oneInteger(earlier, kind)) {
        .yes => return .{ .first = names[j], .second = names[i], .kind = if (kind.integers.len == 1) kind.integers[0] else kind.spelled, .same = .yes },
        .maybe => if (maybe == null) {
            maybe = .{ j, i };
        },
        .no => {},
    };
    const pair = maybe orelse return null;
    return .{ .first = names[pair[0]], .second = names[pair[1]], .kind = kinds[pair[1]].spelled, .same = .maybe };
}

/// Whether two types are one integer in every build, may be in some, or never are.
fn oneInteger(a: Kind, b: Kind) enum { yes, maybe, no } {
    if (a.all and b.all) {
        if (std.mem.eql(u8, a.spelled, b.spelled)) return .yes;
        if (a.integers.len == 1 and b.integers.len == 1 and std.mem.eql(u8, a.integers[0], b.integers[0])) return .yes;
    }
    if (a.unknown or b.unknown) return .maybe;
    for (a.integers) |x| for (b.integers) |y| if (std.mem.eql(u8, x, y)) return .maybe;
    return .no;
}

/// Which of a file's declarations at container level code outside the file may reach (by
/// declaration): a `pub` one in a place that is reached, and one a reached place names
/// (`pub const Link = Edge;`, a public signature's type). A test's names reach nothing.
fn reached(c: *Context, tree: *const Ast, model: *const Model) Context.Error![]const bool {
    const out = try c.allocator.alloc(bool, model.declarations.len);
    @memset(out, false);
    var changed = true;
    while (changed) {
        changed = false;
        for (model.declarations, 0..) |decl, index| {
            if (out[index] or !decl.public or !atContainerLevel(model, decl)) continue;
            if (model.parentOf(decl.node)) |parent| if (!try reachedFrom(c, tree, model, out, parent)) continue;
            out[index] = true;
            changed = true;
        }
        for (model.references) |reference| {
            const decl = reference.declaration orelse continue;
            if (out[@backingInt(decl)] or !atContainerLevel(model, model.declarations[@backingInt(decl)]) or c.inTest(reference.token)) continue;
            if (!try reachedFrom(c, tree, model, out, reference.node)) continue;
            out[@backingInt(decl)] = true;
            changed = true;
        }
    }
    return out;
}

/// Whether a declaration is a container's or the file's own: a constant, variable or function.
fn atContainerLevel(model: *const Model, decl: Model.Declaration) bool {
    if (decl.kind != .variable and decl.kind != .function) return false;
    const kind = model.scopes[@backingInt(decl.scope)].kind;
    return kind == .container or kind == .file;
}

/// Whether code outside the file may reach the place `node` is in: the declaration at container
/// level that holds it is reached (`reached`), and a function's body is passed only in a type
/// function, whose result is what it returns.
fn reachedFrom(c: *Context, tree: *const Ast, model: *const Model, out: []const bool, node: Ast.Node.Index) Context.Error!bool {
    var child = node;
    while (model.parentOf(child)) |parent| : (child = parent) {
        const name = switch (tree.nodeTag(parent)) {
            .fn_decl => name: {
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, parent).?;
                if (tree.nodeData(parent).node_and_node[1] == child) {
                    const result = proto.ast.return_type.unwrap() orelse return false;
                    const value = try c.facts.resolve(c.file, result);
                    if (value != .primitive or !std.mem.eql(u8, value.primitive, "type")) return false;
                }
                break :name proto.name_token orelse continue;
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => tree.fullVarDecl(parent).?.ast.mut_token + 1,
            else => continue,
        };
        const decl = model.lookup(model.scopeOf(name), tree.tokenSlice(name), name) orelse continue;
        if (model.declarations[@backingInt(decl)].node != parent or !atContainerLevel(model, model.declarations[@backingInt(decl)])) continue;
        return out[@backingInt(decl)];
    }
    return true;
}

/// Whether a name says what it holds identifies something: `id`, `index` or `handle`, alone or
/// as the last word (`node_id`, `nodeIndex`, `nodeID`).
fn identifies(name: []const u8) bool {
    for ([_][]const u8{ "id", "index", "handle", "idx" }) |word| {
        if (std.ascii.eqlIgnoreCase(name, word)) return true;
        if (name.len <= word.len) continue;
        const head = name[0 .. name.len - word.len];
        const tail = name[name.len - word.len ..];
        if (head.len == 0) continue;
        const before = head[head.len - 1];
        if (before == '_' and std.mem.eql(u8, tail, word)) return true;
        // camelCase: the word starts upper case, or is all upper case (`parentID`), after a
        // lower-case letter or digit.
        if (std.ascii.isUpper(tail[0]) and std.ascii.eqlIgnoreCase(tail, word) and (std.mem.eql(u8, tail[1..], word[1..]) or upper(tail)) and (std.ascii.isLower(before) or std.ascii.isDigit(before))) return true;
    }
    return false;
}

/// Whether every byte of a word is an upper-case letter.
fn upper(word: []const u8) bool {
    for (word) |byte| if (!std.ascii.isUpper(byte)) return false;
    return true;
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

/// A017: a state written by two or more functions, switched on, and moved on its own value: a
/// state machine kept by hand, where nothing says which transitions are allowed. A state is what
/// the program switches on to choose what it does, whatever holds it (`stateHold`): an enum; a
/// tagged union's active tag (a store of another is a transition); std's `atomic.Value` of
/// either (`load` reads it; `store`, `swap`, `cmpxchg*` move it); an integer switched on with
/// literal prongs or as its enum. A field is read by meaning: a read `x.state` or
/// `@field(x, "state")`, through any holder of the type, and what carries it on (`carried`: a
/// local, a destructure, `&`, a capture, a conversion, a comparison, a value a switch on it
/// chooses, a parameter it is given as, a getter's or a predicate's calls); a write as
/// `stateWrites` finds it. A move is a write under a switch or a condition on the state, or
/// after a guard on it in its block (`if (f.state != .idle) return;`, a switch with a prong
/// that leaves), or one whose value reads it (`f.state = if (f.state == .a) .b else f.state`,
/// its integer plus one), there or where the function that writes it is called; each function
/// that calls a writer writes it too, where the writer gives no one state fixed where it is
/// made (`fixedFunctions`). A call that does not resolve, given the holder under such a
/// condition, may call a writer: undecided. A kind set where its value is built or read (a
/// table's layout, a date's kind) is data. A field moved on the records a loop walks is moved
/// on each of them: a record's states kept by hand all the same.
pub fn stateMachines(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations, 0..) |decl, index| {
        if (decl.kind != .field or c.inTest(decl.token)) continue;
        const written = (model.containerField(tree, decl.node) orelse continue).ast.type_expr.unwrap() orelse continue;
        const hold = (try stateHold(c, try c.facts.resolve(c.file, written))) orelse continue;
        const holder: Facts.Container = .{ .file = c.file, .scope = decl.scope };
        var uses: std.ArrayList(Facts.Key) = .empty;
        var writes: std.ArrayList(StateWrite) = .empty;
        for (try fieldUses(c, decl.name)) |use| {
            const owner = byPointer(try c.facts.resolve(use.file, use.receiver)) orelse continue;
            if (owner.file != holder.file or owner.scope != holder.scope) continue;
            try uses.append(c.allocator, .{ .file = use.file, .node = use.node });
        }
        try carried(c, &uses, decl.name);
        var switched = false;
        for (uses.items) |use| switched = switched or switchedOn(&c.project.at(use.file).file.tree, &c.project.at(use.file).model, use.node, hold);
        if (!switched) continue;
        try stateWrites(c, .{ .file = c.file, .index = @fromBackingInt(@intCast(index)) }, hold, &writes);
        const fixed = try fixedFunctions(c, writes.items);
        var writers: std.ArrayList(Facts.Key) = .empty;
        var unseen = false;
        for (writes.items) |*write| {
            if (write.unseen) {
                unseen = true;
                continue;
            }
            write.counted = try writersOf(c, write.file, write.node, write.target, fixed, &writers, 0);
            const at = c.project.at(write.file);
            const function = enclosingFunction(&at.model, &at.file.tree, write.node) orelse continue;
            write.kept = if (write.target) |target| try writtenThrough(c, write.file, function, target) == .local else false;
        }
        // With one writer, a call that does not resolve may be one more: its caller.
        if (writers.items.len == 0 or (writers.items.len == 1 and !unseen)) continue;
        const verdict = try moved(c, uses.items, writes.items, holder);
        switch (if (writers.items.len == 1 and verdict == .yes) .maybe else verdict) {
            .no => continue,
            .maybe => {
                try c.undecided(rule, tree.tokenStart(decl.token), .unresolved, "a state written through its address, by a destructure of a value not read or by a function a call that does not resolve may make, may be moved on its own value");
                continue;
            },
            .yes => {},
        }
        try c.at(rule, decl.token, try c.allocator.print("'{s}' is a state machine kept by hand: written in {d} functions, moved on its own value and switched on; aegis state.Machine states which transitions there are", .{ decl.name, writers.items.len }));
    }
}

/// Adds to `uses` the reads that carry a read of the state on, by what the value is: what is
/// made of it (read past `orelse`'s left side, `.?`, `.*`, `&`, parentheses, a conversion, a
/// comparison and the logic over one, `atomic.Value`'s `load`, a `switch` or an `if` whose
/// value its condition chooses), and where that goes: each reference to a local it
/// initializes or is stored in (`const now = j.state;`, `const next = switch (j.state) ...`),
/// one a destructure takes it into, what an `if` or a `while` captures of it, each parameter of
/// a function of the program it is given as, and each call of a function that returns it (a
/// getter, a predicate), and from those in turn.
fn carried(c: *Context, uses: *std.ArrayList(Facts.Key), name: []const u8) Context.Error!void {
    var next: usize = 0;
    while (next < uses.items.len and uses.items.len < 256) : (next += 1) {
        const use = uses.items[next];
        const tree = &c.project.at(use.file).file.tree;
        const model = &c.project.at(use.file).model;
        var at = use.node;
        const parent = while (model.parentOf(at)) |parent| : (at = parent) {
            if (try madeOf(c, use.file, parent, at, name)) continue;
            break parent;
        } else null;
        const node = parent orelse continue;
        var local: ?Model.Declaration.Id = null;
        if (tree.fullVarDecl(node)) |variable| {
            if (variable.ast.init_node.unwrap() != at) continue;
            local = declaredBy(model, node);
        } else if (tree.nodeTag(node) == .assign) {
            const target, const value = tree.nodeData(node).node_and_node;
            if (value != at or tree.nodeTag(target) != .identifier) continue;
            local = (model.reference(target) orelse continue).declaration;
        } else if (captureOf(tree, node, at)) |token| {
            for (model.declarations, 0..) |record, i| if (record.kind == .capture and record.token == token) {
                local = @fromBackingInt(@intCast(i));
            };
        } else if (tree.nodeTag(node) == .@"return") {
            const function = enclosingFunction(model, tree, node) orelse continue;
            for (try callsOf(c, use.file, function)) |call| try carry(c, uses, call);
            continue;
        } else if (destructured(tree, model, node, at)) |variable| {
            local = declaredBy(model, variable) orelse localOf(tree, model, variable);
        } else {
            try parameterOf(c, uses, use.file, node, at);
            continue;
        }
        const d = local orelse continue;
        for (model.references) |reference| if (reference.declaration == d) try carry(c, uses, .{ .file = use.file, .node = reference.node });
    }
}

/// Whether `parent` gives a value made of `at`, its operand, that carries a read of the state
/// `state` on (`carried`). A value a `switch` or an `if` on it chooses carries it unless each it
/// may choose is read from another place (`otherPlace`): `if (p.len == 1) p.one else
/// table[p.start + i]` gives a code point, not the state.
fn madeOf(c: *Context, file: Project.FileId, parent: Ast.Node.Index, at: Ast.Node.Index, state: []const u8) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    switch (tree.nodeTag(parent)) {
        .unwrap_optional, .grouped_expression, .deref, .address_of, .bool_not => return true,
        .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .bool_and, .bool_or => return true,
        .@"orelse" => return tree.nodeData(parent).node_and_node[0] == at,
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(parent));
            for ([_][]const u8{ "@as", "@enumFromInt", "@fromBackingInt", "@intFromEnum", "@backingInt", "@intCast", "@truncate", "@atomicLoad" }) |each| if (std.mem.eql(u8, name, each)) return true;
            return false;
        },
        // `x.state.load(order)`: the state an atomic.Value holds, read.
        .field_access => return std.mem.eql(u8, tree.tokenSlice(tree.nodeData(parent).node_and_token[1]), "load"),
        else => {},
    }
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&buffer, parent)) |call| return tree.nodeTag(call.ast.fn_expr) == .field_access and call.ast.fn_expr == at and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(at).node_and_token[1]), "load");
    if (tree.fullSwitch(parent)) |choice| {
        if (choice.ast.condition != at) return false;
        for (choice.ast.cases) |case| if (!try otherPlace(c, file, tree.fullSwitchCase(case).?.ast.target_expr, state)) return true; // unreachable: a switch's cases are cases
        return false;
    }
    if (tree.fullIf(parent)) |branch| {
        if (branch.ast.cond_expr != at or branch.payload_token != null) return false;
        const otherwise = branch.ast.else_expr.unwrap() orelse return true;
        return !try otherPlace(c, file, branch.ast.then_expr, state) or !try otherPlace(c, file, otherwise, state);
    }
    return false;
}

/// Whether `value` is read from a place other than the state `name`, by the place it names
/// (Facts.accesses.pathOf): another field of a holder (`p.one`), or an element (`table[i]`). A
/// field `@field` names by a name it computes may be the state.
fn otherPlace(c: *Context, file: Project.FileId, value: Ast.Node.Index, name: []const u8) Context.Error!bool {
    const place = (try Facts.accesses.pathOf(c.facts, file, value)).steps[0];
    return switch (place.kind) {
        .field => !std.mem.eql(u8, place.name orelse return false, name),
        .index => true,
        else => false,
    };
}

/// The local a variable declaration declares.
fn declaredBy(model: *const Model, node: Ast.Node.Index) ?Model.Declaration.Id {
    for (model.declarations, 0..) |record, i| if (record.kind == .variable and record.node == node) return @fromBackingInt(@intCast(i));
    return null;
}

/// The variable a destructure takes `at`, an element of the tuple it destructures, into
/// (`const now, const n = .{ j.state, j.n }`).
fn destructured(tree: *const Ast, model: *const Model, node: Ast.Node.Index, at: Ast.Node.Index) ?Ast.Node.Index {
    var elements: [2]Ast.Node.Index = undefined;
    const tuple = tree.fullArrayInit(&elements, node) orelse return null;
    const position = std.mem.findScalar(Ast.Node.Index, tuple.ast.elements, at) orelse return null;
    const statement = model.parentOf(node) orelse return null;
    if (tree.nodeTag(statement) != .assign_destructure) return null;
    const full = tree.assignDestructure(statement);
    if (full.ast.value_expr != node or position >= full.ast.variables.len) return null;
    return full.ast.variables[position];
}

/// Adds the references to the parameter of each function of the program a call gives `at` to,
/// a bound receiver first.
fn parameterOf(c: *Context, uses: *std.ArrayList(Facts.Key), file: Project.FileId, node: Ast.Node.Index, at: Ast.Node.Index) Context.Error!void {
    const call = (try Facts.calls.at(c.facts, file, node)) orelse return;
    const args = switch (call.args) {
        .known => |args| args,
        .unknown => return,
    };
    const position = std.mem.findScalar(Ast.Node.Index, args, at) orelse return;
    const choices: []const Facts.Decl = switch (call.callee) {
        .function => |*one| one[0..1],
        .choice => |all| all,
        .any => return,
    };
    const program = try Program.get(c);
    for (choices) |choice| {
        const decl = (try originKnown(c, choice)) orelse continue;
        if (!program.own(decl.file)) continue;
        const callee_tree = &c.project.at(decl.file).file.tree;
        const callee_model = &c.project.at(decl.file).model;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = callee_tree.fullFnProto(&buffer, callee_model.declarations[@backingInt(decl.index)].node) orelse continue;
        var it = proto.iterate(callee_tree);
        var i: usize = 0;
        while (it.next()) |param| : (i += 1) {
            if (i != position) continue;
            const name = param.name_token orelse break;
            for (callee_model.declarations, 0..) |record, d| if (record.kind == .parameter and record.token == name) {
                for (callee_model.references) |reference| if (reference.declaration == @as(Model.Declaration.Id, @fromBackingInt(@intCast(d)))) try carry(c, uses, .{ .file = decl.file, .node = reference.node });
            };
            break;
        }
    }
}

/// The name token an `if` or a `while` captures its condition `condition` as, past `*`.
fn captureOf(tree: *const Ast, node: Ast.Node.Index, condition: Ast.Node.Index) ?Ast.TokenIndex {
    const cond, const payload = if (tree.fullIf(node)) |branch|
        .{ branch.ast.cond_expr, branch.payload_token }
    else if (tree.fullWhile(node)) |loop|
        .{ loop.ast.cond_expr, loop.payload_token }
    else
        return null;
    if (cond != condition) return null;
    const token = payload orelse return null;
    return if (tree.tokenTag(token) == .asterisk) token + 1 else token;
}

fn carry(c: *Context, uses: *std.ArrayList(Facts.Key), use: Facts.Key) Context.Error!void {
    for (uses.items) |seen| if (seen.file == use.file and seen.node == use.node) return;
    try uses.append(c.allocator, use);
}

/// A write of a state field: the node it is made at, the value it writes where one is read, and
/// whether a value not read may be one chosen on the state's own (through its address, a
/// destructure of no literal), which memory code the program does not hold writes is not: it stores bytes.
/// A write to memory the function holds by its own name (`here`, `madeHere`) is its own: its
/// callers write nothing through it.
/// A call whose callee does not resolve (a function pointer's, a comptime function's) given
/// what reaches the holder (`unseen`) writes nothing of its own: what the program's functions it
/// may call write is found where they write it, std's chooses no state, and code the program
/// does not hold is called by name (`extern`). It may call a writer, and so may move the state
/// where it is called under a condition on it, or make one more function that writes it.
/// One that makes the value it writes, not a state of a record held before (`writersOf`), is
/// not `counted`; one of a local its function keeps is `kept`, moved there or nowhere.
const StateWrite = struct { file: Project.FileId, node: Ast.Node.Index, target: ?Ast.Node.Index = null, value: ?Ast.Node.Index, unread: bool = true, unseen: bool = false, counted: bool = true, kept: bool = false };

/// Each write of the state field `field` in the program's files, as Facts.accesses finds them by
/// meaning: a store (`=`, a destructure's place, a memory builtin's, `@atomicStore`), and a
/// literal of its holder stored over a value (`j.* = .{}` resets it). A store that reads it
/// first (`op=`, `@atomicRmw`) reads it in its value. A copy of a whole holder from another
/// place (`a = b`, `j.* = p.*`, std's `append` of one or `std.mem.sort` over them) carries a
/// state chosen where its value was made: no write; a value made here (a literal, a call's
/// result, a constant, a choice of them: `madeValue`) is one. A holder's
/// address taken (a method's receiver) is none either: what is written through it is, at its
/// own site, by its type; the state's own address (`&x.state`) is a write of no value read, and
/// a tagged union's payload taken by address none. Memory code the program does not hold writes
/// over it (bytes, `extern`) is a write that chooses no state on its own value; a call into the
/// program's own functions (a comptime function's, as Facts.calls binds it) is none of its own,
/// their writes found where they are made; one that does not resolve is `unseen`. A store of `undefined` gives it no state. A holder whose type does
/// not resolve is read as no holder of it, as its uses are.
fn stateWrites(c: *Context, field: Facts.Decl, hold: StateHold, writes: *std.ArrayList(StateWrite)) Context.Error!void {
    const program = try Program.get(c);
    const field_tree = &c.project.at(field.file).file.tree;
    const declared = (c.project.at(field.file).model.containerField(field_tree, c.project.at(field.file).model.declarations[@backingInt(field.index)].node) orelse return).ast.type_expr.unwrap() orelse return;
    const state = try c.facts.resolve(field.file, declared);
    var files: std.ArrayList(Project.FileId) = .empty;
    for (c.project.sources) |*each| {
        if (each.input.classification == .@"test" or !program.own(each.id)) continue;
        try files.append(c.allocator, each.id);
    }
    var found_sites = Facts.accesses.writes(c.facts, .{ .field = field }, files.items);
    while (try found_sites.next()) |site| {
        if (site.reach == .named or site.reach == .unresolved) continue;
        const tree = &c.project.at(site.file).file.tree;
        const value: ?Ast.Node.Index = switch (site.kind) {
            .init, .read => continue,
            // A pointer to a whole holder writes it by its type, at a site of its own; one to
            // the state alone (`&x.state`) may write it as anything, but for what an
            // atomic.Value's own operations do with it (`atomicWrite`).
            // A tagged union's payload taken by address (`.a => |*p|`) is written through it,
            // never its tag: no write of the state.
            .address => if (site.reach == .holder or (hold == .tagged and payloadCapture(tree, site.node))) continue else if (hold == .atomic) switch (atomicWrite(tree, &c.project.at(site.file).model, site.target orelse site.node)) {
                .read => continue,
                .write => |value| value,
                .unknown => null,
            } else null,
            .set => if (site.value) |value| written: {
                // `undefined` gives it no state: reading it after is illegal.
                if (undefinedValue(tree, value)) continue;
                if (site.reach == .holder and !try madeValue(c, site.file, value, state, 0)) continue;
                break :written value;
            } else null,
            .update => site.node,
            // std's copies of whole holders (`append`, `std.mem.sort`) carry states made where
            // their values were, and code given a pointer to const writes none; other code over
            // the holder (`extern`) writes bytes.
            .covered => if (site.reach == .holder and try coveredRead(c, site.file, site.node, site.target)) continue else null,
            // A program the unit is read for may write any state, by code not seen here.
            .open => null,
        };
        var unseen = site.kind == .open;
        // A view that reads the holder as other bytes, handed to a function the program holds,
        // is written there through a parameter of another type: here, not where it is made.
        const as_bytes = if (site.target) |given| try Facts.accesses.reinterprets(c.facts, site.file, given) else false;
        if (site.kind == .covered and !as_bytes) if (try Facts.calls.at(c.facts, site.file, site.node)) |call| switch (try heldBodies(c, &call)) {
            .all => continue,
            .unknown => unseen = true,
            .some => {},
        };
        try writes.append(c.allocator, .{ .file = site.file, .node = site.node, .target = site.target, .value = value, .unread = site.kind != .covered, .unseen = unseen });
    }
}

/// Whether a call's callees are all functions of the program with a body, whose writes are
/// found where they are made (`all`); one that does not resolve (`unknown`); or some code the
/// program does not hold (`extern`).
fn heldBodies(c: *Context, call: *const Facts.calls.Call) Context.Error!enum { all, some, unknown } {
    const choices: []const Facts.Decl = switch (call.callee) {
        .function => |*one| one[0..1],
        .choice => |all| all,
        .any => return .unknown,
    };
    const program = try Program.get(c);
    for (choices) |choice| {
        const decl = (try originKnown(c, choice)) orelse return .unknown;
        if (!program.own(decl.file)) return .some;
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        if (record.kind != .function) return .some;
        const parent = c.project.at(decl.file).model.parentOf(record.node) orelse return .some;
        if (c.project.at(decl.file).file.tree.nodeTag(parent) != .fn_decl) return .some;
    }
    return .all;
}

/// Whether `node`, where an access is made, is a switch prong that captures its payload.
fn payloadCapture(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => tree.fullSwitchCase(node).?.payload_token != null, // unreachable: the tag is a prong's.
        else => false,
    };
}

/// Whether a call's caller chooses the state of the value it returns: one of its callees takes
/// a parameter of the state's type, or one that may be (`anytype`), or a callee does not
/// resolve (`at(.running)`). Another chooses it where it makes it, by its own reading.
fn choosesState(c: *Context, file: Project.FileId, node: Ast.Node.Index, state: Facts.Value) Context.Error!bool {
    const call = (try Facts.calls.at(c.facts, file, node)) orelse return true;
    const choices: []const Facts.Decl = switch (call.callee) {
        .function => |*one| one[0..1],
        .choice => |all| all,
        .any => return true,
    };
    const kind = switch (state) {
        .container, .instance => |k| k,
        else => return true,
    };
    for (choices) |choice| {
        const decl = (try originKnown(c, choice)) orelse return true;
        const callee_tree = &c.project.at(decl.file).file.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = callee_tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return true;
        var it = proto.iterate(callee_tree);
        while (it.next()) |param| {
            const written = param.type_expr orelse return true;
            switch (try c.facts.resolve(decl.file, written)) {
                .container, .instance => |k| if (k.file == kind.file and k.scope == kind.scope) return true,
                .unknown => return true,
                else => {},
            }
        }
    }
    return false;
}

/// Whether `node` is `undefined`.
fn undefinedValue(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "undefined");
}

/// Whether a whole holder's value `node` is one made here, which sets a state, rather than a
/// copy of another place's, which carries the state chosen there (`a = b`, `j.* = p.*`): a
/// literal, a constant, a call's result where the caller chooses its state (`choosesState`),
/// or a choice (`if`, `switch`) of one; through `@as`, parentheses, a local's initializer and
/// a labeled block's break. A constructor's value (`f.* = try File.init(bytes)`) carries the
/// state chosen where it is made.
fn madeValue(c: *Context, file: Project.FileId, node: Ast.Node.Index, state: Facts.Value, depth: u8) Context.Error!bool {
    if (depth == 8) return true;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var structs: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&structs, node) != null) return true;
    var calls: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&calls, node) != null) return choosesState(c, file, node, state);
    if (tree.fullIf(node)) |branch| {
        if (try madeValue(c, file, branch.ast.then_expr, state, depth + 1)) return true;
        return if (branch.ast.else_expr.unwrap()) |other| madeValue(c, file, other, state, depth + 1) else false;
    }
    if (tree.fullSwitch(node)) |choice| {
        for (choice.ast.cases) |case_node| if (try madeValue(c, file, tree.fullSwitchCase(case_node).?.ast.target_expr, state, depth + 1)) return true; // unreachable: a switch's cases are cases.
        return false;
    }
    switch (tree.nodeTag(node)) {
        .grouped_expression => return madeValue(c, file, tree.nodeData(node).node_and_token[0], state, depth + 1),
        .@"try" => return madeValue(c, file, tree.nodeData(node).node, state, depth + 1),
        .builtin_call_two, .builtin_call_two_comma => {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@as")) return true;
            const value = tree.nodeData(node).opt_node_and_opt_node[1].unwrap() orelse return true;
            return madeValue(c, file, value, state, depth + 1);
        },
        .identifier => {
            const d = (model.reference(node) orelse return true).declaration orelse return true;
            const record = model.declarations[@backingInt(d)];
            if (record.kind != .variable) return false;
            const variable = tree.fullVarDecl(record.node) orelse return true;
            // A constant's value is made where it is declared; a var's may be copied in later.
            if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
            return madeValue(c, file, variable.ast.init_node.unwrap() orelse return true, state, depth + 1);
        },
        .field_access => {
            // A declaration of a type or a namespace (`Job.empty`) is a constant; a field is a place.
            const held = try c.facts.resolve(file, tree.nodeData(node).node_and_token[0]);
            return held == .container;
        },
        .deref, .array_access, .unwrap_optional => return false,
        else => return true,
    }
}

/// Whether the call `node`, which covers a whole holder given as `target`, writes no state of
/// it: std's (`append`, `std.mem.sort`), or each callee's parameter there a pointer to const.
fn coveredRead(c: *Context, file: Project.FileId, node: Ast.Node.Index, target: ?Ast.Node.Index) Context.Error!bool {
    const call = (try Facts.calls.at(c.facts, file, node)) orelse return false;
    // A parameter that points at const only reads, through whatever view it is handed.
    if (try constParameter(c, &call, target)) return true;
    // Handed through a view that reads it as other bytes (`std.mem.asBytes(j)`) to one that may
    // write, it is written as bytes, whatever state they make, not copied whole.
    if (target) |given| if (try Facts.accesses.reinterprets(c.facts, file, given)) return false;
    const choices: []const Facts.Decl = switch (call.callee) {
        .function => |*one| one[0..1],
        .choice => |all| all,
        .any => return false,
    };
    const program = try Program.get(c);
    for (choices) |choice| {
        const decl = (try originKnown(c, choice)) orelse return false;
        if (!program.std_files.contains(@backingInt(decl.file))) return false;
    }
    return true;
}

/// Whether each function a call may call takes the argument `target` (`&x`, `x`) as a pointer
/// to const.
fn constParameter(c: *Context, call: *const Facts.calls.Call, target: ?Ast.Node.Index) Context.Error!bool {
    const args = switch (call.args) {
        .known => |args| args,
        .unknown => return false,
    };
    const tree = &c.project.at(call.file).file.tree;
    const model = &c.project.at(call.file).model;
    var at = target orelse return false;
    var position = std.mem.findScalar(Ast.Node.Index, args, at);
    while (position == null) {
        at = model.parentOf(at) orelse return false;
        if (tree.nodeTag(at) != .address_of and tree.nodeTag(at) != .grouped_expression) return false;
        position = std.mem.findScalar(Ast.Node.Index, args, at);
    }
    const choices: []const Facts.Decl = switch (call.callee) {
        .function => |*one| one[0..1],
        .choice => |all| all,
        .any => return false,
    };
    for (choices) |choice| {
        const decl = (try originKnown(c, choice)) orelse return false;
        const callee_tree = &c.project.at(decl.file).file.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = callee_tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return false;
        var it = proto.iterate(callee_tree);
        var i: usize = 0;
        const constant = while (it.next()) |param| : (i += 1) {
            if (i != position.?) continue;
            const pointer = callee_tree.fullPtrType(param.type_expr orelse break false) orelse break false;
            break pointer.const_token != null;
        } else false;
        if (!constant) return false;
    }
    return true;
}

/// What a call of an atomic.Value's operation on the state (`x.state.store(v, o)`), `at` the
/// state, does with it: `load` reads it; `store` and `swap` write their value; `cmpxchg*` and
/// the read-modify-writes write a value chosen on its own (the call); another, or an access
/// that is no call, may write anything.
fn atomicWrite(tree: *const Ast, model: *const Model, at: Ast.Node.Index) union(enum) { read, write: Ast.Node.Index, unknown } {
    const node = model.parentOf(at) orelse return .unknown;
    if (tree.nodeTag(node) != .field_access or tree.nodeData(node).node_and_token[0] != at) return .unknown;
    const name = tree.tokenSlice(tree.nodeData(node).node_and_token[1]);
    if (std.mem.eql(u8, name, "load")) return .read;
    const call_node = model.parentOf(node) orelse return .unknown;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, call_node) orelse return .unknown;
    if (call.ast.fn_expr != node) return .unknown;
    if (std.mem.eql(u8, name, "store") or std.mem.eql(u8, name, "swap")) return if (call.ast.params.len > 0) .{ .write = call.ast.params[0] } else .unknown;
    return .{ .write = call_node };
}

/// Whether the field read at `node` is a switch's operand, read past `orelse`'s left side, `.?`,
/// `.*`, `&`, parentheses, `@as`, `@atomicLoad` and an atomic.Value's `load`; an integer's
/// (`integral`) only where it is made its enum on the way (`@enumFromInt`, `@fromBackingInt`)
/// or the switch's prongs are literals, as a state's are.
fn switchedOn(tree: *const Ast, model: *const Model, node: Ast.Node.Index, hold: StateHold) bool {
    var at = node;
    var converted = hold != .integral;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.fullSwitch(parent)) |choice| return choice.ast.condition == at and (converted or literalProngs(tree, choice));
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, parent)) |call| {
            if (call.ast.fn_expr != at or tree.nodeTag(at) != .field_access) return false;
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeData(at).node_and_token[1]), "load")) return false;
            continue;
        }
        switch (tree.nodeTag(parent)) {
            .unwrap_optional, .grouped_expression, .address_of, .deref => {},
            .@"orelse" => if (tree.nodeData(parent).node_and_node[0] != at) return false,
            .field_access => if (hold != .atomic or !std.mem.eql(u8, tree.tokenSlice(tree.nodeData(parent).node_and_token[1]), "load")) return false,
            .builtin_call_two, .builtin_call_two_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(parent));
                if (std.mem.eql(u8, name, "@enumFromInt") or std.mem.eql(u8, name, "@fromBackingInt")) {
                    converted = true;
                } else if (!std.mem.eql(u8, name, "@as")) return false;
            },
            // `@atomicLoad(T, &x.state, order)`: the state, loaded.
            .builtin_call, .builtin_call_comma => {
                var args_buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, parent, &args_buffer);
                if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parent)), "@atomicLoad") or args.len != 3 or args[1] != at) return false;
            },
            else => return false,
        }
    }
    return false;
}

/// Whether a switch's prongs are literals (`0 =>`, `'a' =>`, `1...3 =>`), as a state coded as
/// an integer's are.
fn literalProngs(tree: *const Ast, choice: Ast.full.Switch) bool {
    var any = false;
    for (choice.ast.cases) |case_node| {
        const case = tree.fullSwitchCase(case_node).?; // unreachable: a switch's cases are cases.
        for (case.ast.values) |value| {
            const literal = switch (tree.nodeTag(value)) {
                .number_literal, .char_literal => true,
                .switch_range => tree.nodeTag(tree.nodeData(value).node_and_node[0]) == .number_literal or tree.nodeTag(tree.nodeData(value).node_and_node[0]) == .char_literal,
                else => false,
            };
            if (!literal) return false;
            any = true;
        }
    }
    return any;
}

/// Adds to `writers` the function a write at `node` is made in, by what holds the place it
/// writes there (`target`, `writtenThrough`), and whether it counts: a write of a record the function
/// makes and returns (a constructor's, through the helpers it hands it to) is the state chosen
/// where the value is made, no write of a state held before, and counts for no function. One of
/// a local it keeps is its own. One through a parameter is made, through each call of the
/// program, in what the caller gives there, and counts where some caller's does or where none
/// in the program calls it. Another (a global's, one through what is not followed) is made by
/// each function that calls one that writes, too (a setter's callers write it), unless every
/// write it makes gives one state fixed where it is made (`fixedFunctions`): its callers choose
/// none.
fn writersOf(c: *Context, file: Project.FileId, node: Ast.Node.Index, target: ?Ast.Node.Index, fixed: []const Facts.Key, writers: *std.ArrayList(Facts.Key), depth: u8) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const function = enclosingFunction(model, tree, node) orelse return true;
    for (writers.items) |seen| if (seen.file == file and seen.node == function) return true;
    const held: Through = if (depth == 4) .other else try writtenThrough(c, file, function, target orelse return add(c, writers, file, function));
    const stays = for (fixed) |one| {
        if (one.file == file and one.node == function) break true;
    } else false;
    switch (held) {
        .made => return false,
        .local => {},
        .parameter => |position| {
            // A function giving one state fixed where it is made adds no caller as a writer,
            // but its write is still made in what each caller gives it.
            var scratch: std.ArrayList(Facts.Key) = .empty;
            const calls = try callsOf(c, file, function);
            var counts = calls.len == 0;
            for (calls) |call| {
                const given = try argumentAt(c, call, position);
                if (try writersOf(c, call.file, call.node, given, fixed, if (stays) &scratch else writers, depth + 1)) counts = true;
            }
            if (!counts) return false;
        },
        .other => if (!stays) for (try callsOf(c, file, function)) |call| {
            _ = try writersOf(c, call.file, call.node, null, fixed, writers, depth + 1);
        },
    }
    return add(c, writers, file, function);
}

fn add(c: *Context, writers: *std.ArrayList(Facts.Key), file: Project.FileId, function: Ast.Node.Index) Context.Error!bool {
    for (writers.items) |seen| if (seen.file == file and seen.node == function) return true;
    try writers.append(c.allocator, .{ .file = file, .node = function });
    return true;
}

/// What holds a place in a function (`writtenThrough`): a local it makes and returns, a local it keeps,
/// a parameter by its position (a bound receiver first), or another.
const Through = union(enum) { made, local, parameter: usize, other };

/// What holds the place `node` names in `function`: read to its root through members,
/// elements, slices, `.?`, `.*`, `&` and parentheses, a capture to what it captures, and a
/// constant pointer to what it is made from (`const m = &c.model;`). A `var` holding a pointer,
/// a global, and a root that does not resolve are another.
fn writtenThrough(c: *Context, file: Project.FileId, function: Ast.Node.Index, node: Ast.Node.Index) Context.Error!Through {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = node;
    var steps: u8 = 0;
    while (steps < 32) : (steps += 1) {
        switch (tree.nodeTag(at)) {
            .field_access, .unwrap_optional, .grouped_expression => at = tree.nodeData(at).node_and_token[0],
            .deref, .address_of => at = tree.nodeData(at).node,
            .array_access, .slice_open => at = tree.nodeData(at).node_and_node[0],
            .slice, .slice_sentinel => at = tree.fullSlice(at).?.ast.sliced, // unreachable: the tag is a slice's.
            .identifier => {
                const d = (model.reference(at) orelse return .other).declaration orelse return .other;
                const record = model.declarations[@backingInt(d)];
                if (enclosingFunction(model, tree, record.node) != function and record.node != function) return .other;
                switch (record.kind) {
                    .parameter => return if (parameterPosition(tree, model, function, d)) |position| .{ .parameter = position } else .other,
                    .capture => at = capturedBy(tree, model, record) orelse return .other,
                    .variable => {
                        const variable = tree.fullVarDecl(record.node) orelse return .other;
                        const by_value = switch (try c.facts.resolve(file, at)) {
                            .instance, .array, .optional, .literal, .reified => true,
                            // Its type as written where its value does not resolve.
                            .unknown => if (variable.ast.type_node.unwrap()) |written| tree.fullPtrType(written) == null and tree.nodeTag(written) != .optional_type else false,
                            else => false,
                        };
                        if (by_value) return if (returnsLocal(tree, model, function, d)) .made else .local;
                        // A pointer: what a constant one is made from.
                        if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return .other;
                        at = variable.ast.init_node.unwrap() orelse return .other;
                    },
                    else => return .other,
                }
            },
            else => {
                // A call's result held by pointer (`c.project.at(file)`): what its receiver holds.
                var buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buffer, at) orelse return .other;
                if (tree.nodeTag(call.ast.fn_expr) != .field_access) return .other;
                at = tree.nodeData(call.ast.fn_expr).node_and_token[0];
            },
        }
    }
    return .other;
}

/// What a capture captures: a `for` loop's input at its position, an `if`'s or a `while`'s
/// condition (not its error), a switch's.
fn capturedBy(tree: *const Ast, model: *const Model, record: Model.Declaration) ?Ast.Node.Index {
    if (tree.fullFor(record.node)) |loop| return loop.ast.inputs[Model.capturePosition(tree, loop, record.token) orelse return null];
    if (tree.fullIf(record.node)) |branch| return if (branch.error_token == record.token) null else branch.ast.cond_expr;
    if (tree.fullWhile(record.node)) |loop| return if (loop.error_token == record.token) null else loop.ast.cond_expr;
    if (tree.fullSwitchCase(record.node) != null) return (tree.fullSwitch(model.parentOf(record.node) orelse return null) orelse return null).ast.condition;
    return null;
}

/// Whether `function` returns the local `d` itself (`return model;`).
fn returnsLocal(tree: *const Ast, model: *const Model, function: Ast.Node.Index, d: Model.Declaration.Id) bool {
    for (model.references) |reference| {
        if (reference.declaration != d) continue;
        const parent = model.parentOf(reference.node) orelse continue;
        if (tree.nodeTag(parent) == .@"return" and enclosingFunction(model, tree, parent) == function) return true;
    }
    return false;
}

/// The argument a call gives at `position`, a bound receiver first; null where it is not known.
fn argumentAt(c: *Context, call: Facts.Key, position: usize) Context.Error!?Ast.Node.Index {
    const facts_call = (try Facts.calls.at(c.facts, call.file, call.node)) orelse return null;
    const args = switch (facts_call.args) {
        .known => |args| args,
        .unknown => return null,
    };
    return if (position < args.len) args[position] else null;
}

/// The functions each of whose writes of the state gives one and the same state fixed where it
/// is made (`fixedState`): a function whose writes give two (`if (done) .done else .running`)
/// leaves its callers to choose.
fn fixedFunctions(c: *Context, writes: []const StateWrite) Context.Error![]const Facts.Key {
    var out: std.ArrayList(Facts.Key) = .empty;
    for (writes) |write| {
        const tree = &c.project.at(write.file).file.tree;
        const model = &c.project.at(write.file).model;
        const function = enclosingFunction(model, tree, write.node) orelse continue;
        const known = for (out.items) |one| {
            if (one.file == write.file and one.node == function) break true;
        } else false;
        if (known) continue;
        var state: ?[]const u8 = null;
        const every = for (writes) |other| {
            if (other.file != write.file or enclosingFunction(model, tree, other.node) != function) continue;
            const value = other.value orelse break false;
            const name = (try fixedState(c, other.file, value)) orelse break false;
            if (state) |earlier| if (!std.mem.eql(u8, earlier, name)) break false;
            state = name;
        } else true;
        if (every) try out.append(c.allocator, .{ .file = write.file, .node = function });
    }
    return out.items;
}

/// The state `node` gives whoever calls the function it is in, by its name: an enum literal
/// (`.done`), a member of an enum type (`Phase.done`), the integer of one
/// (`@backingInt(Phase.done)`), a number or a character, a tagged union's literal by the one
/// field it names (`.{ .lent = dir }`: its tag is the state, its payload what the state
/// holds); null for another value.
fn fixedState(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?[]const u8 {
    const tree = &c.project.at(file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, node)) |literal| {
        if (literal.ast.fields.len != 1) return null;
        return tree.tokenSlice(tree.firstToken(literal.ast.fields[0]) - 2);
    }
    switch (tree.nodeTag(node)) {
        .enum_literal, .number_literal, .char_literal => return tree.tokenSlice(tree.nodeMainToken(node)),
        .grouped_expression => return fixedState(c, file, tree.nodeData(node).node_and_token[0]),
        .field_access => {
            const held = try c.facts.resolve(file, tree.nodeData(node).node_and_token[0]);
            if (held != .container or !isEnum(c, held.container)) return null;
            return tree.tokenSlice(tree.nodeData(node).node_and_token[1]);
        },
        .builtin_call_two, .builtin_call_two_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            if (!std.mem.eql(u8, name, "@backingInt") and !std.mem.eql(u8, name, "@intFromEnum")) return null;
            const operand = tree.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse return null;
            return fixedState(c, file, operand);
        },
        else => return null,
    }
}

/// The calls of the program that call the function declared by `function` in `file`, as
/// Facts.calls reads each callee: a method's, a free function's, `@call`'s, each of a choice.
fn callsOf(c: *Context, file: Project.FileId, function: Ast.Node.Index) Context.Error![]const Facts.Key {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const proto = tree.nodeData(function).node_and_node[0];
    const program = try Program.get(c);
    var found: std.ArrayList(Facts.Key) = .empty;
    for (c.project.sources) |*each| {
        if (each.input.classification == .@"test" or !program.own(each.id)) continue;
        for (try Facts.calls.in(c.facts, each.id)) |*call| {
            const choices: []const Facts.Decl = switch (call.callee) {
                .function => |*one| one[0..1],
                .choice => |all| all,
                .any => continue,
            };
            for (choices) |choice| {
                const decl = (try originKnown(c, choice)) orelse continue;
                if (decl.file != file or model.declarations[@backingInt(decl.index)].node != proto) continue;
                try found.append(c.allocator, .{ .file = each.id, .node = call.node });
                break;
            }
        }
    }
    return found.items;
}

/// Whether one of `writes` is a move: under a switch or a condition on the field (one of `uses`),
/// one whose value reads the field, or in a function a call under one makes (not one of a local
/// its function keeps: no caller's condition reads that record). A write that makes its value
/// (not `counted`) is none. A write whose value is not read (through its address, a destructure
/// of no literal) may be one, and so may one a call that does not resolve (`act(j)`, a function
/// pointer) may make, given the holder, under such a condition.
fn moved(c: *Context, uses: []const Facts.Key, writes: []const StateWrite, holder: Facts.Container) Context.Error!enum { no, maybe, yes } {
    var maybe = try unresolvedUnder(c, uses, holder);
    for (writes) |write| {
        if (!write.counted) continue;
        const tree = &c.project.at(write.file).file.tree;
        const model = &c.project.at(write.file).model;
        if (write.value) |value| for (uses) |use| {
            if (use.file != write.file) continue;
            const token = tree.nodeMainToken(use.node);
            if (token >= tree.firstToken(value) and token <= tree.lastToken(value)) return .yes;
        };
        const function = enclosingFunction(model, tree, write.node) orelse continue;
        if (write.unseen) {
            maybe = maybe or conditioned(tree, model, uses, write.file, write.node, function);
            continue;
        }
        if (conditioned(tree, model, uses, write.file, write.node, function)) return .yes;
        const callers: []const Facts.Key = if (write.kept) &.{} else try callsOf(c, write.file, function);
        for (callers) |call| {
            const call_tree = &c.project.at(call.file).file.tree;
            const call_model = &c.project.at(call.file).model;
            const caller = enclosingFunction(call_model, call_tree, call.node) orelse continue;
            if (conditioned(call_tree, call_model, uses, call.file, call.node, caller)) return .yes;
        }
        maybe = maybe or (write.value == null and write.unread);
    }
    return if (maybe) .maybe else .no;
}

/// Whether a call of the program that does not resolve, given a value of the holder's type,
/// is made under a condition on the state: it may call a writer (`moved`).
fn unresolvedUnder(c: *Context, uses: []const Facts.Key, holder: Facts.Container) Context.Error!bool {
    const program = try Program.get(c);
    for (c.project.sources) |*each| {
        if (each.input.classification == .@"test" or !program.own(each.id)) continue;
        const tree = &each.file.tree;
        const model = &c.project.at(each.id).model;
        for (try Facts.calls.in(c.facts, each.id)) |*call| {
            if (call.callee != .any) continue;
            const args = switch (call.args) {
                .known => |args| args,
                .unknown => continue,
            };
            const given = for (args) |arg| {
                const owner = byPointer(try c.facts.resolve(each.id, arg)) orelse continue;
                if (owner.file == holder.file and owner.scope == holder.scope) break true;
            } else false;
            if (!given) continue;
            const function = enclosingFunction(model, tree, call.node) orelse continue;
            if (conditioned(tree, model, uses, each.id, call.node, function)) return true;
        }
    }
    return false;
}

/// Whether `node` sits in a branch a switch or an `if`/`while` on one of `uses` selects, within
/// `function`, or after a guard on one in its block or one around it.
fn conditioned(tree: *const Ast, model: *const Model, uses: []const Facts.Key, file: Project.FileId, node: Ast.Node.Index, function: Ast.Node.Index) bool {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (parent == function) return false;
        // A guard before it in its block (`if (j.state != .idle) return;`,
        // `switch (j.state) { .idle => {}, else => return }`) chooses it as a condition around
        // it does: an `if` or a `switch` on the state that can leave.
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.blockStatements(&buffer, parent)) |statements| for (statements) |statement| {
            if (statement == at) break;
            const condition = if (tree.fullIf(statement)) |guard| guard.ast.cond_expr else if (tree.fullSwitch(statement)) |guard| guard.ast.condition else continue;
            if (!reads(tree, uses, file, condition) or !mayLeave(tree, statement)) continue;
            return true;
        };
        const condition = if (tree.fullSwitch(parent)) |s|
            s.ast.condition
        else if (tree.fullIf(parent)) |branch|
            branch.ast.cond_expr
        else if (tree.fullWhile(parent)) |loop|
            loop.ast.cond_expr
        else
            continue;
        if (condition == at) continue;
        if (reads(tree, uses, file, condition)) return true;
    }
    return false;
}

/// Whether one of `uses` is within `node`.
fn reads(tree: *const Ast, uses: []const Facts.Key, file: Project.FileId, node: Ast.Node.Index) bool {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    for (uses) |use| {
        if (use.file != file) continue;
        const token = tree.nodeMainToken(use.node);
        if (token >= first and token <= last) return true;
    }
    return false;
}

/// Whether some way through `node` does not go on to the statement after it: it holds a
/// `return`, a `break`, a `continue` or an `unreachable`.
fn mayLeave(tree: *const Ast, node: Ast.Node.Index) bool {
    for (tree.firstToken(node)..tree.lastToken(node) + 1) |token| switch (tree.tokenTag(@intCast(token))) {
        .keyword_return, .keyword_break, .keyword_continue, .keyword_unreachable => return true,
        else => {},
    };
    return false;
}

/// What holds a state (`stateMachines`): an enum naming a tag, a tagged union (its active tag),
/// an integer, or std's `atomic.Value` of one.
const StateHold = enum { enumerated, tagged, integral, atomic };

fn stateHold(c: *Context, value: Facts.Value) Context.Error!?StateHold {
    if (integer(value) != null) return .integral;
    const container = byValue(value) orelse return null;
    // An enum that names no tag (`enum(u32) { _ }`) is an id: switched on, it picks what it
    // names, not a state.
    if (isEnum(c, container)) return if (namesTags(c, container)) .enumerated else null;
    if (taggedUnion(c, container)) return .tagged;
    if (try atomicValue(c, container)) return .atomic;
    return null;
}

/// Whether a container declares a field other than `_`: an enum's named tag.
fn namesTags(c: *Context, value: Facts.Container) bool {
    const tree = &c.project.at(value.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, c.project.at(value.file).model.scopes[@backingInt(value.scope)].node) orelse return true;
    for (container.ast.members) |member| {
        const field = c.project.at(value.file).model.containerField(tree, member) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(field.ast.main_token), "_")) return true;
    }
    return false;
}

/// Whether a container is a union with a tag (`union(enum)`, `union(Tag)`).
fn taggedUnion(c: *Context, value: Facts.Container) bool {
    const tree = &c.project.at(value.file).file.tree;
    const node = c.project.at(value.file).model.scopes[@backingInt(value.scope)].node;
    if (node == .root) return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, node) orelse return false;
    if (tree.tokenTag(container.ast.main_token) != .keyword_union) return false;
    return container.ast.enum_token != null or container.ast.arg != .none;
}

/// Whether a container is one std's `atomic.Value` makes.
fn atomicValue(c: *Context, held: Facts.Container) Context.Error!bool {
    const decls = switch (try Governed.declarations(c, "std", "atomic.Value")) {
        .decls => |decls| decls,
        .none, .unknown => return false,
    };
    const tree = &c.project.at(held.file).file.tree;
    const model = &c.project.at(held.file).model;
    const first = model.scopes[@backingInt(held.scope)].first;
    for (decls) |each| {
        const decl = (try originKnown(c, each)) orelse continue;
        if (decl.file != held.file) continue;
        const function = model.parentOf(model.declarations[@backingInt(decl.index)].node) orelse continue;
        if (first >= tree.firstToken(function) and first <= tree.lastToken(function)) return true;
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
            const origin = (try originKnown(c, decl)) orelse {
                try c.undecided(rule, 0, .unresolved, try c.allocator.print("std.{s} does not resolve to its declaration: no resource of it is judged", .{found.target.declaration}));
                continue;
            };
            const value = try c.facts.declaration(origin);
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
        .pointer => |inner| byPointer(inner.child.*),
        .optional => |inner| byPointer(inner.*),
        else => null,
    };
}
