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

/// What releases a std resource, by std's declarations (`Governed.isStd`): its `close`, a
/// server's `deinit` (it closes the listening socket), a child's `kill` or `wait`, and the
/// system calls that close a handle. A std function that only shares a name is no release.
const release_paths = [_][]const u8{ "Io.File.close", "Io.File.closeMany", "Io.Dir.close", "Io.Dir.closeMany", "Io.net.Stream.close", "Io.net.Socket.close", "Io.net.Socket.closeMany", "Io.net.Server.deinit", "process.Child.kill", "process.Child.wait", "os.linux.close", "os.windows.CloseHandle" };

/// The fields that hold a std resource's own handle, by std's declarations: what writes or
/// releases one writes or releases the resource.
const handle_paths = [_][]const u8{ "Io.File.handle", "Io.Dir.handle", "Io.net.Stream.socket", "Io.net.Server.socket", "Io.net.Socket.handle" };

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
/// local's declaration whose block's next statement stores `null` into the same place
/// (`Facts.accesses.samePlace`).
fn movedOut(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var use = try Facts.accesses.useOf(c.facts, c.file, node);
    if (use == .carried and use.carried.how == .unwrapped) use = try Facts.accesses.useOf(c.facts, c.file, use.carried.into);
    const declaration = switch (use) {
        .initializes => |declaration| declaration,
        else => return false,
    };
    if (tree.fullVarDecl(declaration) == null) return false;
    const block = model.parentOf(declaration) orelse return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block) orelse return false;
    const at = std.mem.findScalar(Ast.Node.Index, statements, declaration) orelse return false;
    if (at + 1 >= statements.len) return false;
    const next = statements[at + 1];
    const store = (try storeAt(c, c.file, next)) orelse return false;
    if (store.kind != .set) return false;
    const place = store.target orelse return false;
    if (!Facts.isNull(tree, store.value orelse return false)) return false;
    return try Facts.accesses.samePlace(c.facts, c.file, place, node) == .yes;
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
            if (try movedOut(c, node)) continue;
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
            // A tuple a function's result type writes is what the function returns: one whose every
            // return reads what is already held hands over no owner (`views`), as a result of the
            // resource itself does.
            if (resultOf(c, @fromBackingInt(@intCast(i)))) |function| if (try views(c, resources, function, 0, null)) continue;
            try c.at(rule, first, try c.allocator.print("a tuple's field holds a std.{s} by value: aegis own.Owned names its one owner and checks it is released once; a borrow of it is its borrow().*, which is never released", .{resource_paths[which]}));
        }
    }
}

/// The function of the checked file whose result type is the container `node`, or its payload
/// (`!struct { File }`, `?struct { File }`); null for any other container.
fn resultOf(c: *Context, node: Ast.Node.Index) ?Facts.Decl {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var child = node;
    var parent = model.parentOf(child) orelse return null;
    while (true) : ({
        child = parent;
        parent = model.parentOf(child) orelse return null;
    }) switch (Facts.accesses.formOf(tree.nodeTag(parent))) {
        .grouped, .optional_type => {},
        .error_union => if (tree.nodeData(parent).node_and_node[1] != child) return null,
        else => break,
    };
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, parent) orelse return null;
    if (proto.ast.return_type.unwrap() != child) return null;
    for (model.declarations, 0..) |decl, index| {
        if (decl.kind == .function and decl.node == parent) return .{ .file = c.file, .index = @fromBackingInt(@intCast(index)) };
    }
    return null;
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
        if (try c.facts.typeIsType(function.file, result)) {
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
    // A function's declaration is its prototype's.
    const proto = tree.nodeData(function).node_and_node[0];
    for (model.declarations, 0..) |decl, index| {
        if (decl.kind == .function and decl.node == proto) return c.facts.hasGenericParameter(.{ .file = c.file, .index = @fromBackingInt(@intCast(index)) });
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
    if (try statementCall(c, c.file, node)) return;
    switch (try heldBy(c, resources, try c.facts.resolve(c.file, node), 0)) {
        .resource, .unknown => try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "which function this call calls does not resolve, and what it makes may hold a std resource by value: it may be a generic's owner handed over"),
        .generic => if (!inGeneric(c, node)) try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "which function this call calls does not resolve, and what it makes may hold a std resource by value: it may be a generic's owner handed over"),
        .other => {},
    }
}

/// Whether the call `node`, past `try` and parentheses, is a statement of a block or a `defer`.
fn statementCall(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const model = &c.project.at(file).model;
    var at = node;
    while (true) switch (try Facts.accesses.useOf(c.facts, file, at)) {
        .carried => |onward| switch (onward.how) {
            .tried, .grouped => at = onward.into,
            else => return false,
        },
        // A body's or a `defer`'s statement; a file's own level holds none.
        .statement => return model.parentOf(at) != null,
        else => return false,
    };
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
    const decl = switch (try c.facts.definition(c.file, node)) {
        .decl => |decl| decl,
        .none, .unknown => return false,
    };
    if (decl.file != c.file) return false;
    return try readsReleased(c, c.file, decl.index, 0) == .yes;
}

const Stored = enum { no, yes, unknown };

/// Whether a function keeps its parameter at `position` in a resource field: an assignment of
/// it (or a capture or local made from it) to a field of a resource type, a literal naming it
/// for one, or a call that passes it on to a function that does; one that does not resolve may.
/// std's never does.
/// Whether `function`'s parameter at `position` is declared by a type parameter of a function
/// around it (`item: T` in `fn ArrayList(comptime T: type) type`).
fn genericElement(c: *Context, function: Facts.Decl, position: usize) Context.Error!bool {
    const tree = &c.project.at(function.file).file.tree;
    const model = &c.project.at(function.file).model;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(function.index)].node) orelse return false;
    var params = proto.iterate(tree);
    var at: usize = 0;
    const declared = while (params.next()) |param| : (at += 1) {
        if (at == position) break param.type_expr orelse return false;
    } else return false;
    return switch (try c.facts.definition(function.file, declared)) {
        .decl => |decl| c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind == .parameter,
        .none, .unknown => false,
    };
}

fn stores(c: *Context, resources: []const ?Facts.Container, function: Facts.Decl, position: usize, depth: u8) Context.Error!Stored {
    // std is given no owner by value: what keeps a handle (`File.Reader`, `File.Writer`) is lent
    // a copy of it. A container's element (`ArrayList(T).append(gpa, item: T)`, a parameter of a
    // type its type function is given) is kept whatever it is.
    if (try c.facts.standard(function.file)) return if (try genericElement(c, function, position)) .yes else .no;
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
    switch (try Facts.accesses.useOf(c.facts, file, node)) {
        .carried => |onward| switch (onward.how) {
            .grouped, .tried => return kept(c, resources, file, onward.into, depth),
            else => return .no,
        },
        // `h.f = v`: kept where it is stored into a field (by name, or by a name `@field`
        // computes: any field).
        .stored => |site| {
            const path = try Facts.accesses.pathOf(c.facts, file, site.target orelse return .no);
            const step = path.steps[0];
            if (step.kind != .field) return .no;
            const holder = byPointer(step.holder orelse return .unknown) orelse return .unknown;
            return ownedField(c, resources, holder, step.name orelse return .unknown);
        },
        .field_of => |field| {
            const name = tree.tokenSlice(field.name);
            // A literal a local holds is kept where that local's field goes.
            if (literalLocal(tree, model, field.literal)) |id| return keptLocal(c, resources, file, id, name, depth);
            const holder = byValue(try c.facts.literalType(file, field.literal)) orelse return .unknown;
            return ownedField(c, resources, holder, name);
        },
        else => {},
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
    const model = &c.project.at(file).model;
    const parent = model.parentOf(node) orelse return .none;
    // A receiver's parent is the callee `x.f`, a tuple element's `@call`'s third operand.
    const use = try Facts.accesses.useOf(c.facts, file, node);
    const tuple = use == .element_of;
    const holder = if (use == .member or tuple) model.parentOf(parent) orelse return .none else parent;
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
        const read = switch (try Facts.accesses.useOf(c.facts, file, reference.node)) {
            .member => |read| read,
            else => return .unknown,
        };
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

/// The reads of a field `name` in the program's files: `x.name` (`Facts.memberUses`) and each
/// `@field` that may name it (`Facts.fieldUses`), one whose name is computed not `named`.
fn fieldUses(c: *Context, name: []const u8) Context.Error![]const FieldUse {
    var uses: std.ArrayList(FieldUse) = .empty;
    for (try c.facts.memberUses(name)) |use| {
        const step = (try Facts.accesses.memberRead(c.facts, use.file, use.node)) orelse continue;
        try uses.append(c.allocator, .{ .file = use.file, .node = use.node, .receiver = step.receiver.? }); // unreachable: a member's step has its holder
    }
    for (try c.facts.fieldUses(c.allocator, name)) |use| {
        try uses.append(c.allocator, .{ .file = use.key.file, .node = use.key.node, .receiver = use.holder, .named = !use.computed });
    }
    return uses.items;
}

/// The receiver, name and name's token of a field read (`Facts.accesses.memberOf`): `x.name`,
/// or `@field(x, "name")` with the name it spells (null where it is computed).
fn fieldAccess(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!?struct { receiver: Ast.Node.Index, name: ?[]const u8, token: Ast.TokenIndex } {
    const step = (try Facts.accesses.memberRead(c.facts, c.file, node)) orelse return null;
    // `x.name` at its name, `@field` at the builtin.
    const token = if (Facts.isBuiltin(tree, node, "@field")) tree.nodeMainToken(node) else tree.lastToken(node);
    return .{ .receiver = step.receiver.?, .name = step.name, .token = token }; // unreachable: a member's step has its holder
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
    var use = try Facts.accesses.useOf(c.facts, file, node);
    if (use == .address) return addressWrite(c, resources, file, use.address);
    if (pointerCapture(tree, model, model.parentOf(node) orelse return .none, node)) return .address;
    if (use == .member) switch (try handleOf(c, file, use.member)) {
        .yes => use = try Facts.accesses.useOf(c.facts, file, use.member),
        .no => {},
        // A member whose declaration does not resolve: as std's handle, written as the field
        // is; as another member, read. None only where both say none.
        .unknown => return if (try writtenBy(c, resources, file, try Facts.accesses.useOf(c.facts, file, use.member)) == .none) .none else .unknown,
    };
    return writtenBy(c, resources, file, use);
}

/// How the use `use` writes what it uses: `=`, or a destructure's target (its element where the
/// value is a literal, else part of a value that may hold one).
fn writtenBy(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, use: Facts.accesses.Use) Context.Error!Write {
    switch (use) {
        .written => |site| return if (try filled(c, resources, file, site.value orelse return .unknown)) .none else .owner,
        .unknown => return .unknown,
        else => return .none,
    }
}

/// Whether the member read `access` in `file` is a field holding a std resource's handle
/// (`handle_paths`), by the declaration it names; unknown where it does not resolve.
fn handleOf(c: *Context, file: Project.FileId, access: Ast.Node.Index) Context.Error!Facts.Is {
    const decl = switch (try c.facts.definition(file, access)) {
        .decl => |decl| decl,
        .none => return .no,
        .unknown => |why| return .{ .unknown = why },
    };
    return stdAmong(c, decl, &handle_paths);
}

/// Whether `decl` is one of std's declarations at `paths`; unknown where one does not resolve
/// and none is it.
fn stdAmong(c: *Context, decl: Facts.Decl, paths: []const []const u8) Context.Error!Facts.Is {
    var unknown: ?Facts.Unknown = null;
    for (paths) |path| switch (try Governed.isStd(c, decl, path)) {
        .yes => return .yes,
        .no => {},
        .unknown => |why| unknown = why,
    };
    return if (unknown) |why| .{ .unknown = why } else .no;
}

/// Whether std's function `callee` releases a resource it is given (`release_paths`).
fn stdReleases(c: *Context, callee: Facts.Decl) Context.Error!Stored {
    return switch (try stdAmong(c, callee, &release_paths)) {
        .yes => .yes,
        .no => .no,
        .unknown => .unknown,
    };
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
        const write: Write = switch (try Facts.accesses.useOf(c.facts, file, reference.node)) {
            // `p.*`: written as the field is.
            .dereferenced => |deref| try writeOf(c, resources, file, deref),
            // `p.handle`: written as the field is; another member is read.
            .member => |access| switch (try handleOf(c, file, access)) {
                .yes => try writeOf(c, resources, file, reference.node),
                .no => .none,
                // Judged both ways by `writeOf`.
                .unknown => if (try writeOf(c, resources, file, reference.node) == .none) .none else .unknown,
            },
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
            // The prong's item names the field's tag of the subject's type (`Facts.tagNamed`).
            const named = for (case.ast.values) |value| {
                const tag = (try c.facts.tagNamed(file, value)) orelse continue;
                if (tag.container.file == holder.file and tag.container.scope == holder.scope and std.mem.eql(u8, tag.name, decl.name)) break true;
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
    if (try c.facts.literalOf(file, value)) |literal| if (literal == .undefined) return true;
    return viewed(c, resources, file, value, 0, null);
}

/// Whether what `node` in `file` holds (a field read, a capture or local made from it, its
/// `handle`, its address, a function's return of it) is released where it is read: a method
/// called on it that releases its receiver, std's by declaration (`release_paths`), or passed to
/// a function that releases that parameter (`releasesParameter`). Passed where nothing resolves,
/// or further than is followed, it may be.
fn released(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!Stored {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    if (depth >= 8) return .unknown;
    const next = depth + 1;
    const parent = model.parentOf(node) orelse return .no;
    const use = try Facts.accesses.useOf(c.facts, file, node);
    switch (use) {
        // What gives its value on whole: parentheses, `.?`, `try`, `orelse` and `catch`, a
        // branch's or a prong's result, a `break`'s value.
        .carried => |onward| return released(c, file, onward.into, next),
        // Its address, its pointee, its memory sliced or indexed (`(&f)[0..1]`, std's
        // `closeMany` idiom) holds it.
        .address, .dereferenced, .element, .sliced, .index => |whole| return released(c, file, whole, next),
        // Converted (`@as(T, x)`), the value is it.
        .builtin_argument => |argument| {
            if (argument.position == 1 and Facts.isBuiltin(tree, argument.call, "@as")) return released(c, file, argument.call, next);
            // The holder of a member a type function reads by a name it computes (`@field(k.held,
            // name)`, over each of its type's fields): released where that member is, read for
            // its value only where it is not.
            if (argument.position == 0 and Facts.isBuiltin(tree, argument.call, "@field") and try typeFunctionOf(c, file, node) != null) {
                const step = (try Facts.accesses.memberRead(c.facts, file, argument.call)) orelse return .unknown;
                if (step.name == null) return released(c, file, argument.call, next);
            }
        },
        // Compared, it is read for its value only.
        .compared => return .no,
        // In arithmetic (a `handle` summed) the result may still be it; given to `x op= v`, the
        // place's reads are followed.
        .operand => |whole| {
            const update = (try storeAt(c, file, whole)) orelse return released(c, file, whole, next);
            return placeReleased(c, file, update.target orelse return .unknown, next);
        },
        // A place written, its own value going back into it: not read here.
        .updated, .written, .discarded => return .no,
        // A destructure's value (a tuple) may hand it on.
        .destructured => return .unknown,
        // Its handle, released as it is; a method called on it, by what the method does with
        // its receiver (`argumentOf`); any other member is read for its value only.
        // A member whose declaration does not resolve is judged both ways: as std's handle,
        // followed; as another member, read for its value only. Where both say none, none.
        .member => |access| switch (try handleOf(c, file, access)) {
            .yes => return released(c, file, access, next),
            // A method on what a type function's parameter holds (`b.v.close()` in `Box(T)`), its
            // declaration known at no binding here: by its name, as every instance shares it.
            // Reading it at each binding is the next branch's.
            .unknown => if (try Facts.accesses.useOf(c.facts, file, access) == .callee) {
                if (try typeFunctionOf(c, file, access) == null) return .unknown;
                return if (releasing(tree.tokenSlice(tree.nodeData(access).node_and_token[1]))) .yes else .no;
            } else return if (try released(c, file, access, next) == .no) .no else .unknown,
            .no => if (try Facts.accesses.useOf(c.facts, file, access) != .callee) return .no,
        },
        .returned => |ret| return releasedReturn(c, file, ret, next),
        // A copy stored: into a local, by each read of it; into another field, by each read of
        // that field of its holder's type.
        .stored => |site| return placeReleased(c, file, site.target orelse return .unknown, next),
        .callee => return .no,
        else => {},
    }
    switch (try argumentOf(c, file, node)) {
        .at => |at| return releasesParameter(c, &at.call, at.position, next),
        .unknown => return .unknown,
        .none => {},
    }
    switch (use) {
        // A copy put in a literal, by each read of the field it names (`literalReleased`); a
        // tuple's or an array's element may be.
        .field_of => |field| return literalReleased(c, file, field.literal, tree.tokenSlice(field.name), next),
        .element_of => |element| return elementReleased(c, file, element.literal, element.position, null, next),
        // Switched on, by each read of its prongs' captures (`.file => |x| x.close(io)`).
        .switched => |chosen| {
            var result: Stored = .no;
            for (tree.fullSwitch(chosen).?.ast.cases) |case| for (model.declarations, 0..) |decl, i| { // unreachable: what is switched on is a switch's
                if (decl.kind != .capture or decl.node != case) continue;
                result = join(result, try readsReleased(c, file, @fromBackingInt(@intCast(i)), next));
                if (result == .yes) return .yes;
            };
            return result;
        },
        // A local made from it, by each read of it.
        .initializes => |declaration| for (model.declarations, 0..) |decl, i| {
            if (decl.kind == .variable and decl.node == declaration) return readsReleased(c, file, @fromBackingInt(@intCast(i)), next);
        },
        // A capture of it, by each read of it; a condition that captures nothing reads it for
        // its value only.
        .tested, .looped => {
            for (model.declarations, 0..) |decl, i| {
                if (decl.kind != .capture or decl.node != parent or !captures(tree, parent, decl.token, node)) continue;
                return readsReleased(c, file, @fromBackingInt(@intCast(i)), next);
            }
            if (tree.fullIf(parent)) |branch| if (branch.payload_token == null) return .no;
            if (tree.fullWhile(parent)) |loop| if (loop.payload_token == null) return .no;
        },
        else => {},
    }
    // Any other place it goes is not followed: it may be released there.
    return .unknown;
}

/// The innermost type function (one returning `type`, `Facts.typeIsType`) whose body holds
/// `node` in `file`; null where none does.
fn typeFunctionOf(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Facts.Decl {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = node;
    while (enclosingFunction(model, tree, at)) |function| : (at = function) {
        // A function's declaration is its prototype's.
        const prototype = tree.nodeData(function).node_and_node[0];
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, prototype) orelse continue;
        const returned = proto.ast.return_type.unwrap() orelse continue;
        if (!try c.facts.typeIsType(file, returned)) continue;
        for (model.declarations, 0..) |record, i| {
            if (record.kind == .function and record.node == prototype) return .{ .file = file, .index = @fromBackingInt(@intCast(i)) };
        }
        return null;
    }
    return null;
}

fn releasing(name: []const u8) bool {
    for ([_][]const u8{ "close", "closeMany", "deinit", "kill", "wait" }) |each| if (std.mem.eql(u8, name, each)) return true;
    return false;
}

/// Whether a copy stored into the place `target` names in `file` is `released`: a local's, by
/// each read of it; a field's, by each read of that field of its holder's type; any other place
/// may be.
fn placeReleased(c: *Context, file: Project.FileId, target: Ast.Node.Index, depth: u8) Context.Error!Stored {
    const path = try Facts.accesses.pathOf(c.facts, file, target);
    const step = path.steps[0];
    switch (step.kind) {
        .root => {
            const decl = switch (path.root) {
                .decl => |decl| decl,
                .none, .unknown => return .unknown,
            };
            if (decl.file != file or c.project.at(file).model.declarations[@backingInt(decl.index)].kind == .field) return .unknown;
            return readsReleased(c, file, decl.index, depth);
        },
        .field => {
            const holder = byPointer(step.holder orelse return .unknown) orelse return .unknown;
            return typeReleased(c, holder, step.name orelse return .unknown, depth);
        },
        else => return .unknown,
    }
}

/// The store whose node is `node` in `file` (an assignment, a compound assignment, a
/// destructure), from `Facts.accesses.storesIn`; null for any other node.
fn storeAt(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Facts.accesses.Site {
    for (try Facts.accesses.storesIn(c.facts, file)) |site| if (site.node == node) return site;
    return null;
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
            if (try cc.facts.standard(callee.file)) return stdReleases(cc, callee);
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
    const tag = c.facts.member(holder, name);
    const named: []const Prong = if (tag) |field| (if (prongs.named.get(field)) |list| list.items else &.{}) else &.{};
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
    /// Answers by the keeper's field and the held field, each by its declaration.
    found: std.AutoHashMapUnmanaged(Kept, Stored) = .empty,
    /// The reads in progress, innermost last: a read met again while still being read.
    open: std.ArrayList(Reading) = .empty,
    met_open: usize = 0,

    const Kept = struct { keeper: Facts.Decl, held: Facts.Decl, holder: Facts.Container };
    const Reading = struct { keeper: Facts.Container, field: []const u8, name: []const u8, holder: ?Facts.Container };

    fn reading(self: *const KeptReads, one: Reading) bool {
        for (self.open.items) |each| {
            if (!std.meta.eql(each.keeper, one.keeper) or !std.meta.eql(each.holder, one.holder)) continue;
            if (std.mem.eql(u8, each.field, one.field) and std.mem.eql(u8, each.name, one.name)) return true;
        }
        return false;
    }
};

fn keptReleased(c: *Context, keeper: Facts.Container, field: []const u8, name: []const u8, holder: ?Facts.Container) Context.Error!Stored {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const state = try c.facts.memo(KeptReads);
    // Kept where both fields are declarations; a holder whose type does not resolve is read
    // again each time.
    const key: ?KeptReads.Kept = if (holder) |h| (if (c.facts.member(keeper, field)) |keeping| (if (c.facts.member(h, name)) |held| KeptReads.Kept{ .keeper = keeping, .held = held, .holder = h } else null) else null) else null;
    if (key) |k| if (state.found.get(k)) |answer| return answer;
    const one: KeptReads.Reading = .{ .keeper = keeper, .field = field, .name = name, .holder = holder };
    if (state.reading(one)) {
        state.met_open += 1;
        return .no;
    }
    try state.open.append(c.allocator, one);
    const met_open = state.met_open;
    const result = try keptReads(c, keeper, field, name, holder);
    _ = state.open.pop();
    if (key) |k| if (result != .no or state.met_open == met_open) try state.found.put(c.allocator, k, result);
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
    /// By the union's field each tag is.
    named: std.AutoHashMapUnmanaged(Facts.Decl, std.ArrayList(Prong)) = .empty,
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
                    const field = c.facts.member(tag.container, tag.name) orelse {
                        by_literal = false;
                        continue;
                    };
                    const entry = try index.named.getOrPut(gpa, field);
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
    if (try c.facts.standard(callee.file)) return stdReleases(c, callee);
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
                    if (try cc.facts.standard(callee.file)) return stdReleases(cc, callee);
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
    if (!userdata(try c.facts.resolve(c.file, first.type_expr orelse return false))) return false;
    for (c.project.sources) |*source| {
        if (!try Program.owns(c, source.id)) continue;
        const file = source.id;
        const tree = &source.file.tree;
        for (tree.nodes.items(.tag), 0..) |_, i| {
            var buffer: [2]Ast.Node.Index = undefined;
            const literal = tree.fullStructInit(&buffer, @fromBackingInt(@intCast(i))) orelse continue;
            for (literal.ast.fields) |value| {
                // Named, not called: the function, or its address (`&f`). Its last name only
                // narrows what is resolved.
                if (!std.mem.eql(u8, tree.tokenSlice(tree.lastToken(value)), decl.name)) continue;
                const slot = c.facts.member(vtable, tree.tokenSlice(Model.initName(tree, value) orelse continue)) orelse continue;
                if (c.project.at(slot.file).model.declarations[@backingInt(slot.index)].kind != .field) continue;
                const named = try c.facts.resolve(file, value);
                const function = if (named == .pointer) named.pointer.child.* else named;
                switch (function) {
                    .function => |d| if (d.file == c.file and d.index == index) return true,
                    else => {},
                }
            }
        }
    }
    return false;
}

/// Whether a type is `?*anyopaque`, the userdata std's `Io` vtable functions take first.
fn userdata(value: Facts.Value) bool {
    if (value != .optional or value.optional.* != .pointer) return false;
    const pointee = value.optional.pointer.child.*;
    return pointee == .primitive and std.mem.eql(u8, pointee.primitive, "anyopaque");
}

fn viewed(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, node: Ast.Node.Index, depth: u8, bound: ?*const Binding) Context.Error!bool {
    if (depth >= 16) return false;
    // Each value it may give, through parentheses, `.?`, `try`, `orelse` and `catch`, a
    // branch's or a prong's result, a labeled block's `break`s and `@as`: a view where each is.
    // An exit gives none (a prong that never returns, `orelse return null`).
    const leaves = switch (try Facts.accesses.valuesOf(c.facts, file, node)) {
        .leaves => |leaves| leaves,
        .unknown => return false,
    };
    for (leaves) |leaf| if (!try leafViewed(c, resources, file, leaf, depth + 1, bound)) return false;
    return true;
}

/// `viewed` of one value of no form that carries another: a part of a place a view holds, an
/// `own.Owned`'s `borrow().*`, a name, a call, a std resource's literal made from its handle.
fn leafViewed(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, node: Ast.Node.Index, next: u8, bound: ?*const Binding) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    if (Facts.isNull(tree, node)) return true;
    // A name (a member read resolves to its declaration too, and is a place's part below).
    if (try Facts.accesses.memberRead(c.facts, file, node) == null) switch (try c.facts.definition(file, node)) {
        .decl => return nameViewed(c, resources, file, node, next, bound),
        .unknown => return false,
        .none => {},
    };
    const path = try Facts.accesses.pathOf(c.facts, file, node);
    if (path.steps.len > 1) switch (path.steps[0].kind) {
        // An element of what is a view.
        .index => return viewed(c, resources, file, path.steps[1].node, next, bound),
        // A member of what a name holds, through members, elements and payloads: a view where
        // the name is.
        .field => {
            for (path.steps[0 .. path.steps.len - 1]) |step| switch (step.kind) {
                .field, .index, .unwrap => {},
                else => return false,
            };
            if (path.root != .decl) return false;
            return viewed(c, resources, file, path.steps[path.steps.len - 1].node, next, bound);
        },
        // An `own.Owned`'s `borrow().*`: the owner keeps what it lends. Any other `p.*` reads
        // what `p` points at, a view where `p` is one.
        .deref => {
            const pointer = path.steps[1].node;
            const call = (try Facts.calls.at(c.facts, file, pointer)) orelse return viewed(c, resources, file, pointer, next, bound);
            const args = switch (call.args) {
                .known => |args| args,
                .unknown => return false,
            };
            if (call.receiver != .bound or args.len != 1) return false;
            if (!(try readsOwn(c, file, call.callee_expr, "borrow") orelse false)) return false;
            return try c.role(Contract.library, try c.facts.resolve(file, call.receiver.bound)) == .owned;
        },
        else => {},
    };
    if (try Facts.calls.at(c.facts, file, node)) |call| return callViewed(c, resources, file, &call, next, bound);
    // A tuple holds its elements: a view where each one is.
    var elements_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullArrayInit(&elements_buffer, node)) |tuple| {
        if (tuple.ast.type_expr != .none or tuple.ast.elements.len == 0) return false;
        for (tuple.ast.elements) |element| if (!try viewed(c, resources, file, element, next, bound)) return false;
        return true;
    }
    var init_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&init_buffer, node)) |literal| {
        // A std handle made from one it is given: the literal of a std resource type.
        const made = byValue(try c.facts.literalType(file, node)) orelse return false;
        if (find(resources, made) == null) return false;
        for (literal.ast.fields) |value| {
            const field = c.facts.member(made, tree.tokenSlice(Model.initName(tree, value) orelse continue)) orelse continue;
            if (try stdAmong(c, field, &handle_paths) != .yes) continue;
            return viewed(c, resources, file, value, next, bound);
        }
        return false;
    }
    return false;
}

/// What a name holds is a view: `null`, a parameter that is one (or what a call passes it,
/// `Binding`), a capture of one, a declared constant, or a local constant made from one.
fn nameViewed(c: *Context, resources: []const ?Facts.Container, file: Project.FileId, node: Ast.Node.Index, next: u8, bound: ?*const Binding) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    if (Facts.isNull(tree, node)) return true;
    const decl = switch (try c.facts.definition(file, node)) {
        .decl => |decl| decl,
        .none, .unknown => return false,
    };
    if (decl.file != file) return false;
    const record = model.declarations[@backingInt(decl.index)];
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
        return viewed(c, resources, file, c.facts.captureSource(file, record) orelse return false, next, bound);
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
    const args = switch (call.args) {
        .known => |args| args,
        .unknown => return false,
    };
    // An `own.Lent`'s `get()`: a copy its owner lends.
    if (call.receiver == .bound and args.len == 1 and (try readsOwn(c, file, call.callee_expr, "get") orelse false)) {
        if (try c.role(Contract.library, try c.facts.resolve(file, call.receiver.bound)) == .lent) return true;
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
        // Through its address and parentheses, to what takes it.
        var at = reference.node;
        while (true) switch (try Facts.accesses.useOf(c.facts, file, at)) {
            .address => |address| at = address,
            .carried => |onward| if (onward.how == .grouped) {
                at = onward.into;
            } else break,
            else => break,
        };
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
    const bound = if (through) try throughBound(c, c.file, node) else try boundBy(c, c.file, node);
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
    var bound = try boundBy(c, file, node);
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
        // `&g`, or a view of it (`Facts.accesses.pointed`).
        const local = (try localOf(c, file, (try Facts.accesses.pointed(c.facts, file, param)) orelse continue)) orelse continue;
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
fn boundBy(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!Bound {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const unbound: Bound = .{ .statement = node, .declaration = null, .from = node, .value = node };
    var at = node;
    var use = try Facts.accesses.useOf(c.facts, file, at);
    while (use == .carried) {
        const onward = use.carried;
        switch (onward.how) {
            .tried, .grouped, .payload, .prong => {},
            // A labeled block's value; a loop's is not followed.
            .broken => if (tree.fullWhile(onward.into) != null or tree.fullFor(onward.into) != null) break,
            else => break,
        }
        at = onward.into;
        use = try Facts.accesses.useOf(c.facts, file, at);
    }
    const taken_as = at;
    var member: ?[]const u8 = null;
    var from: ?Ast.Node.Index = null;
    switch (use) {
        // `.name = value`: the local's member.
        .field_of => |field| {
            member = tree.tokenSlice(field.name);
            from = node;
            at = field.literal;
            use = try Facts.accesses.useOf(c.facts, file, at);
        },
        // A tuple's element a destructure takes apart.
        .element_of => |element| {
            const statement = switch (try Facts.accesses.useOf(c.facts, file, element.literal)) {
                .destructured => |statement| statement,
                else => return unbound,
            };
            const full = tree.assignDestructure(statement);
            if (element.position >= full.ast.variables.len) return unbound;
            return .{ .statement = statement, .declaration = (try localOf(c, file, full.ast.variables[element.position])) orelse return unbound, .from = node, .value = taken_as };
        },
        else => {},
    }
    switch (use) {
        .initializes => |declaration| {
            if (tree.fullVarDecl(declaration) == null) return unbound;
            return .{ .statement = declaration, .declaration = (try localOf(c, file, declaration)) orelse return unbound, .member = member, .from = from orelse declaration, .value = taken_as };
        },
        .stored => |site| {
            if (model.parentOf(at) != site.node) return unbound;
            return .{ .statement = site.node, .declaration = (try localOf(c, file, site.target orelse return unbound)) orelse return unbound, .member = member, .from = from orelse site.node, .value = taken_as };
        },
        else => return unbound,
    }
}

/// The local variable `node` declares (`var g = ...`, a destructure's `var g`) or names (`g`,
/// by `Facts.definition`; a member is none).
fn localOf(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Model.Declaration.Id {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    if (tree.fullVarDecl(node) != null) {
        for (model.declarations, 0..) |record, i| {
            if (record.kind == .variable and record.node == node) return @fromBackingInt(@intCast(i));
        }
        return null;
    }
    if (try Facts.accesses.memberRead(c.facts, file, node) != null) return null;
    const decl = switch (try c.facts.definition(file, node)) {
        .decl => |decl| decl,
        .none, .unknown => return null,
    };
    if (decl.file != file) return null;
    return if (model.declarations[@backingInt(decl.index)].kind == .variable) decl.index else null;
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
    if (!try onlyHeld(c, file, decl, statement)) return null;
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
        if (branch.ast.else_expr != .none or !try namesLocal(c, file, branch.ast.cond_expr, decl)) return null;
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
    for (try Facts.accesses.storesIn(c.facts, file)) |site| {
        if (site.node != node or site.kind != .set) continue;
        if (try movedBy(c, file, site.value orelse continue, decl)) |call| return call;
    }
    if (tree.nodeTag(node) == .@"return") return if (tree.nodeData(node).opt_node.unwrap()) |value| movedBy(c, file, value, decl) else null;
    const call = (try Facts.calls.at(c.facts, file, node)) orelse return null;
    const method = (try Facts.accesses.memberRead(c.facts, file, call.callee_expr)) orelse return null;
    var receiver = method.receiver.?; // unreachable: a member's step has its holder
    if (call.receiver == .none) return null;
    if (!try guardRelease(c, call.callee)) {
        // A guard whose type does not resolve, as its acquisition does not, is judged as one:
        // its own `deinit` or `release`, which does not resolve with it, releases it.
        if (call.callee != .any or member == .named or try Facts.accesses.memberRead(c.facts, file, receiver) != null) return null;
        const spelled = method.name orelse return null;
        if (!std.mem.eql(u8, spelled, "deinit") and !std.mem.eql(u8, spelled, "release")) return null;
    }
    switch (member) {
        .none => {},
        .named => |name| {
            const field = (try Facts.accesses.memberRead(c.facts, file, receiver)) orelse return null;
            if (!std.mem.eql(u8, field.name orelse return null, name)) return null;
            receiver = field.receiver.?; // unreachable: a member's step has its holder
        },
        .any => if (try Facts.accesses.memberRead(c.facts, file, receiver)) |field| {
            receiver = field.receiver.?; // unreachable: a member's step has its holder
        },
    }
    return if (try namesLocal(c, file, receiver, decl)) node else null;
}

/// The declaration of `file` the name `node` refers to (by `Facts.definition`), of any kind; a
/// member read, a declaration elsewhere and one that does not resolve are none.
fn declarationOf(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Model.Declaration.Id {
    if (try Facts.accesses.memberRead(c.facts, file, node) != null) return null;
    return switch (try c.facts.definition(file, node)) {
        .decl => |found| if (found.file == file) found.index else null,
        .none, .unknown => null,
    };
}

/// Whether `node` names the declaration `decl` of `file` (by `Facts.definition`): a variable or
/// a capture (`if (g) |*h| h.deinit()`); a member read is none.
fn namesLocal(c: *Context, file: Project.FileId, node: Ast.Node.Index, decl: Model.Declaration.Id) Context.Error!bool {
    return try declarationOf(c, file, node) == decl;
}

/// The call `value` is, through `try`, that hands on the guard `decl` holds into its value
/// (`handedOn`), which binds it anew.
fn movedBy(c: *Context, file: Project.FileId, value: Ast.Node.Index, decl: Model.Declaration.Id) Context.Error!?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    var at = Facts.ungrouped(tree, value);
    while (tree.nodeTag(at) == .@"try") at = Facts.ungrouped(tree, tree.nodeData(at).node);
    const call = (try Facts.calls.at(c.facts, file, at)) orelse return null;
    if (!try handedOn(c, file, &call)) return null;
    return if (try namesLocal(c, file, Facts.ungrouped(tree, call.receiver.bound), decl)) at else null;
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
    for (each) |choice| if (try stdAmong(c, choice, &.{ "Io.Future.await", "Io.Future.cancel" }) != .yes) return false;
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
        if (record.kind != .function) return false;
        // The guard type's own `deinit` or `release`, by the declaration it gives the name.
        const guard: Facts.Container = .{ .file = decl.file, .scope = record.scope };
        const own = for ([_][]const u8{ "deinit", "release" }) |name| {
            if (c.facts.member(guard, name)) |declared| if (std.meta.eql(declared, decl)) break true;
        } else false;
        if (!own) return false;
        switch (try guardType(c, guard)) {
            .plain, .ranked => {},
            .no, .unknown => return false,
        }
    }
    return true;
}

/// Whether the guard local `decl` is only held: each use of it a member's (`g.value()`,
/// `g.deinit()`), the statement that binds it, or an `if (g) |*h|`, which copies
/// nothing. A copy, a store, its address taken may keep it past its release.
fn onlyHeld(c: *Context, file: Project.FileId, decl: Model.Declaration.Id, statement: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    for (model.references) |reference| {
        if (reference.declaration != decl) continue;
        const parent = model.parentOf(reference.node) orelse return false;
        if (parent == statement) continue;
        switch (try Facts.accesses.useOf(c.facts, file, reference.node)) {
            // Its address given to the call that binds it (`lockInto(a, &g)`).
            .address => if (reference.token >= tree.firstToken(statement) and reference.token <= tree.lastToken(statement)) continue,
            .member => continue,
            .tested => |branch| if (tree.fullIf(branch)) |full| if (full.payload_token) |payload| if (tree.tokenTag(payload) == .asterisk) continue,
            else => {},
        }
        return false;
    }
    return true;
}

/// Whether `node` is read by `@TypeOf`, which never runs it.
fn typeOnly(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (Facts.isBuiltin(tree, parent, "@TypeOf")) return true;
        if (tree.nodeTag(parent) == .fn_decl) return false;
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
    const statement = try statementCall(c, file, call.node);
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
        // A guarded owner's acquisition, by its declared result's role (`Contract.acquired`):
        // ranked where that is an Order's capability. One whose result does not resolve may be.
        if (record.kind == .function and try c.role(Contract.library, owner) == .guarded) switch (try Contract.acquired(c, decl)) {
            .plain, .ranked => |how| {
                const ranked = how == .ranked;
                // Of a choice, ranked only where each is; read before `lock` is written.
                const found: Lock = .{ .ranked = ranked and (if (lock) |earlier| earlier.ranked else true), .context = if (ranked) try contextOf(c, file, call) else null };
                lock = found;
                continue;
            },
            .unknown => {
                other = true;
                continue;
            },
            .no => {},
        };
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
                const context = if (inner.context_from) |position| try argumentContext(c, file, call, position) else null;
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
        const bound = if (found == .lock and found.lock.through) try throughBound(c, file, call.node) else try boundBy(c, file, call.node);
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
fn argumentContext(c: *Context, file: Project.FileId, call: *const Facts.calls.Call, position: usize) Context.Error!?Model.Declaration.Id {
    const args = switch (call.args) {
        .known => |args| args,
        .unknown => return null,
    };
    if (position >= args.len) return null;
    return contextNamed(c, file, args[position]);
}

/// The local or parameter an argument names, `&` or not, through parentheses: by
/// `Facts.definition` of the name, or of the place `&` takes (`Facts.accesses.pointed`).
fn contextNamed(c: *Context, file: Project.FileId, argument: Ast.Node.Index) Context.Error!?Model.Declaration.Id {
    const tree = &c.project.at(file).file.tree;
    var at = Facts.ungrouped(tree, argument);
    if (try addressOperand(c, file, at)) |place| at = Facts.ungrouped(tree, place);
    if (try Facts.accesses.memberRead(c.facts, file, at) != null) return null;
    const decl = switch (try c.facts.definition(file, at)) {
        .decl => |decl| decl,
        .none, .unknown => return null,
    };
    return if (decl.file == file) decl.index else null;
}

/// The local or parameter a ranked acquisition's `Order.Context` argument names, `&` or not.
fn contextOf(c: *Context, file: Project.FileId, call: *const Facts.calls.Call) Context.Error!?Model.Declaration.Id {
    const args = switch (call.args) {
        .known => |args| args,
        .unknown => return null,
    };
    // The receiver, the Io, the context.
    if (args.len != 3) return null;
    return contextNamed(c, file, args[2]);
}

/// The place `&x` at `node` takes the address of (`Facts.accesses.pointed`, where `node` is that
/// `&` itself); null for any other node.
fn addressOperand(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const place = (try Facts.accesses.pointed(c.facts, file, node)) orelse return null;
    return switch (try Facts.accesses.useOf(c.facts, file, place)) {
        .address => |address| if (address == node) place else null,
        else => null,
    };
}

/// Whether a value is a guard (`guardValue`), and an Order's ranked one.
const Guard = union(enum) { no, plain, ranked, unknown: Facts.Unknown };

/// Whether what a call gives holds a guard by value (`guardHeld`). One that does not resolve
/// is a guard where its declared result names one.
fn guardValue(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!Guard {
    return switch (try guardHeld(c, try c.facts.resolve(file, node))) {
        .unknown => |why| switch ((try Contract.kind(c, file, node, 0)) orelse return .{ .unknown = why }) {
            .guard => .plain,
            .ranked_guard => .ranked,
            else => .{ .unknown = why },
        },
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

/// Whether a container is a guard's, by the role aegis declares for it (`Contract.isGuard`): an
/// owner's guard, or an Order's ranked capability. A `Handoff` holds no lock.
fn guardType(c: *Context, held: Facts.Container) Context.Error!Guard {
    const k = try c.role(Contract.library, .{ .container = held });
    if (!Contract.isGuard(k)) return .no;
    return if (k == .ranked_guard) .ranked else .plain;
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
/// literal prongs or as its enum. One that is not an enum is a state only where the program
/// chooses among literals for it, never moving it by arithmetic (`literalState`). A field is read by meaning: a read `x.state` or
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
        for (uses.items) |use| switched = switched or try switchedOn(c, use.file, use.node, hold);
        if (!switched) continue;
        try stateWrites(c, .{ .file = c.file, .index = @fromBackingInt(@intCast(index)) }, hold, &writes);
        const state: LiteralState = if (hold == .enumerated) .state else try literalState(c, hold, decl.name, .{ .file = c.file, .node = written }, writes.items, uses.items);
        if (state == .value) continue;
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
        if (state == .unknown) {
            try c.undecided(rule, tree.tokenStart(decl.token), .unresolved, "a state written with a name that does not resolve: whether the program chooses among literals for it is not known");
            continue;
        }
        try c.at(rule, decl.token, try c.allocator.print("'{s}' is a state machine kept by hand: written in {d} functions, moved on its own value and switched on; aegis state.Machine states which transitions there are", .{ decl.name, writers.items.len }));
    }
}

/// Whether a state that is not an enum's is one the program chooses among (main's ruling,
/// 11-06): a write gives it a literal choice (an enum literal, a union's tag `.tag` or
/// `.{ .tag = ... }`, an integer literal; a choice of them), and none moves it by arithmetic on
/// its own value (`pos += 1`, `at = at - 1`): that is a counter. A field given only whole
/// values from elsewhere is a value. A write whose value is not read decides neither.
/// What `literalState` finds a field to be: a state; a value; or not known, where a write's
/// value names what does not resolve and no write gives it a literal.
const LiteralState = enum { state, value, unknown };

fn literalState(c: *Context, hold: StateHold, name: []const u8, type_expr: Facts.Key, writes: []const StateWrite, uses: []const Facts.Key) Context.Error!LiteralState {
    // The field's default, what a literal of its holder that names it not gives it.
    const model = &c.project.at(type_expr.file).model;
    const tree_of_field = &c.project.at(type_expr.file).file.tree;
    const default: ?Ast.Node.Index = if (model.parentOf(type_expr.node)) |field| if (model.containerField(tree_of_field, field)) |full| full.ast.value_expr.unwrap() else null else null;
    var literal = false;
    var unknown = false;
    for (writes) |write| {
        const tree = &c.project.at(write.file).file.tree;
        if (opArithmetic(tree, write.node) or opArithmetic(tree, c.project.at(write.file).model.parentOf(write.node) orelse write.node)) return .value;
        // A write whose value is not read (through the field's address, by a destructure of no
        // literal, by a call that does not resolve) may give it a literal choice: not known.
        const value = if (write.unseen) null else write.value;
        const read = value orelse {
            unknown = true;
            continue;
        };
        if (readsSelf(tree, write.file, read, uses, 0)) return .value;
        const choice = try literalChoice(c, write.file, read, hold, name, 0);
        switch (if (choice == .default) if (default) |d| try literalChoice(c, type_expr.file, d, hold, name, 0) else .other else choice) {
            .literal => literal = true,
            .unknown => unknown = true,
            .other, .default => {},
        }
    }
    return if (literal) .state else if (unknown) .unknown else .value;
}

/// Whether a node is a store that computes its target's new value from its old one by
/// arithmetic or bits (`+=`, `-%=`, `<<=`, `|=`).
fn opArithmetic(tree: *const Ast, node: Ast.Node.Index) bool {
    return Facts.accesses.formOf(tree.nodeTag(node)) == .compound_assign;
}

/// Whether `node` computes by arithmetic or bits over a read of the state (`uses`).
fn readsSelf(tree: *const Ast, file: Project.FileId, node: Ast.Node.Index, uses: []const Facts.Key, depth: u8) bool {
    if (depth == 8) return false;
    const at = Facts.ungrouped(tree, node);
    // A binary operator (`accesses.formOf`); a negation or a complement moves nothing by itself.
    if (Facts.accesses.formOf(tree.nodeTag(at)) != .operator or unaryOperator(tree, at)) return false;
    const first = tree.firstToken(at);
    const last = tree.lastToken(at);
    for (uses) |use| {
        if (use.file != file) continue;
        const token = tree.nodeMainToken(use.node);
        if (token >= first and token <= last) return true;
    }
    return false;
}

/// Whether an operator (`accesses.formOf`'s `operator`) takes one operand: `-x`, `~x`, `-%x`.
fn unaryOperator(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .negation or tree.nodeTag(node) == .bit_not or tree.nodeTag(node) == .negation_wrap;
}

/// Whether a written value is a literal choice of the state `hold` (`literalState`): an enum
/// literal or a declared tag (`.idle`, `Phase.idle`), a union's tag literal (`.{ .busy = n }`),
/// an integer literal or an enum tag's integer (`@intFromEnum(Phase.idle)`), or a choice of
/// them; in a literal of the field's holder (`.{ .len = 1 }`), what it gives the field, or
/// `default` where it names it not.
fn literalChoice(c: *Context, file: Project.FileId, node: Ast.Node.Index, hold: StateHold, name: []const u8, depth: u8) Context.Error!enum { literal, default, unknown, other } {
    if (depth == 8) return .other;
    const tree = &c.project.at(file).file.tree;
    if (tree.fullIf(node)) |branch| {
        const then = try literalChoice(c, file, branch.ast.then_expr, hold, name, depth + 1);
        if (then == .literal) return .literal;
        const otherwise = if (branch.ast.else_expr.unwrap()) |other| try literalChoice(c, file, other, hold, name, depth + 1) else .other;
        return if (otherwise == .literal) .literal else if (then == .unknown or otherwise == .unknown) .unknown else .other;
    }
    if (tree.fullSwitch(node)) |choice| {
        var unknown = false;
        for (choice.ast.cases) |case_node| switch (try literalChoice(c, file, tree.fullSwitchCase(case_node).?.ast.target_expr, hold, name, depth + 1)) { // unreachable: a switch's cases are cases.
            .literal => return .literal,
            .unknown => unknown = true,
            .other, .default => {},
        };
        return if (unknown) .unknown else .other;
    }
    var structs: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&structs, node)) |init| {
        // A literal of the holder: what it gives the field.
        for (init.ast.fields) |field| {
            const label = tree.firstToken(field) - 2;
            if (tree.tokenTag(label) == .identifier and std.mem.eql(u8, tree.tokenSlice(label), name)) return literalChoice(c, file, field, hold, name, depth + 1);
        }
        // A union's own literal, of one tag; else the holder's, which gives the field its default.
        if (hold != .integral and init.ast.type_expr == .none and init.ast.fields.len == 1) return .literal;
        return .default;
    }
    // Parentheses (`Facts.ungrouped`) give what they hold.
    const inner = Facts.ungrouped(tree, node);
    if (inner != node) return literalChoice(c, file, inner, hold, name, depth + 1);
    // A builtin (`Facts.builtinArgs`): `@as`'s value; an enum tag's integer, for a state held
    // as one; any other, no literal. `@field` is among them, read as no member here.
    if (Facts.accesses.formOf(tree.nodeTag(node)) == .builtin) {
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        if (args.len == 0 or args.len > 2) return .other;
        if (Facts.isBuiltin(tree, node, "@as")) return if (args.len == 2) literalChoice(c, file, args[1], hold, name, depth + 1) else .other;
        if (hold == .integral and (Facts.isBuiltin(tree, node, "@intFromEnum") or Facts.isBuiltin(tree, node, "@backingInt"))) {
            if (try c.facts.literalOf(file, args[0])) |literal| if (literal == .enum_literal) return .literal;
            if (try Facts.accesses.memberRead(c.facts, file, args[0]) != null) return switch (try declaredTag(c, file, args[0])) {
                .yes => .literal,
                .no => .other,
                .unknown => .unknown,
            };
        }
        return .other;
    }
    // A declared tag (`Phase.idle`), by the declaration the member read names.
    if (try Facts.accesses.memberRead(c.facts, file, node) != null) return if (hold == .integral) .other else switch (try declaredTag(c, file, node)) {
        .yes => .literal,
        .no => .other,
        .unknown => .unknown,
    };
    // A literal (`Facts.literalOf`): an enum literal of a state held as a tag; a number or a
    // character of one held as an integer.
    return switch ((try c.facts.literalOf(file, node)) orelse return .other) {
        .enum_literal => if (hold != .integral) .literal else .other,
        .number, .char => if (hold == .integral) .literal else .other,
        else => .other,
    };
}

/// Whether `node` (`Phase.idle`) names an enum's tag by its declaration: a constant, not a
/// value read from a place; not known where the name does not resolve.
fn declaredTag(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!enum { yes, no, unknown } {
    const decl = switch (try c.facts.definition(file, node)) {
        .decl => |found| found,
        .none => return .no,
        .unknown => return .unknown,
    };
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .field) return .no;
    return if (isEnum(c, .{ .file = decl.file, .scope = record.scope })) .yes else .no;
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
        while (try madeOf(c, use.file, at, name)) |whole| at = whole;
        const node = model.parentOf(at) orelse continue;
        var local: ?Model.Declaration.Id = null;
        switch (try Facts.accesses.useOf(c.facts, use.file, at)) {
            .initializes => |declaration| local = declaredBy(model, declaration),
            .stored => |site| {
                if (site.node != node) continue;
                local = try declarationOf(c, use.file, site.target orelse continue);
            },
            .returned => |ret| {
                const function = enclosingFunction(model, tree, ret) orelse continue;
                for (try callsOf(c, use.file, function)) |call| try carry(c, uses, call);
                continue;
            },
            .element_of => |element| {
                const variable = (try destructured(c, use.file, element.literal, element.position)) orelse {
                    try parameterOf(c, uses, use.file, node, at);
                    continue;
                };
                local = declaredBy(model, variable) orelse try localOf(c, use.file, variable);
            },
            else => if (captureOf(tree, node, at)) |token| {
                for (model.declarations, 0..) |record, i| if (record.kind == .capture and record.token == token) {
                    local = @fromBackingInt(@intCast(i));
                };
            } else {
                try parameterOf(c, uses, use.file, node, at);
                continue;
            },
        }
        const d = local orelse continue;
        for (model.references) |reference| if (reference.declaration == d) try carry(c, uses, .{ .file = use.file, .node = reference.node });
    }
}

/// What gives a value made of `at` that carries a read of the state `state` on (`carried`):
/// `.?`, parentheses, `orelse`'s and `catch`'s left side, `.*`, `&`, a comparison and the logic
/// over one, a conversion, std's `atomic.Value` `load` of it, and a `switch` or an `if` whose
/// value its condition chooses, unless each it may choose is read from another place
/// (`otherPlace`): `if (p.len == 1) p.one else table[p.start + i]` gives a code point, not the
/// state. Null where none does.
fn madeOf(c: *Context, file: Project.FileId, at: Ast.Node.Index, state: []const u8) Context.Error!?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    switch (try Facts.accesses.useOf(c.facts, file, at)) {
        .carried => |onward| return switch (onward.how) {
            .unwrapped, .grouped, .payload => onward.into,
            else => null,
        },
        .dereferenced, .address, .compared => |whole| return whole,
        .logic => |logic| return logic.whole,
        .builtin_argument => |argument| {
            const name = Facts.builtinName(tree, argument.call) orelse return null;
            for ([_][]const u8{ "@as", "@enumFromInt", "@fromBackingInt", "@intFromEnum", "@backingInt", "@intCast", "@truncate", "@atomicLoad" }) |each| if (std.mem.eql(u8, name, each)) return argument.call;
            return null;
        },
        // `x.state.load(order)`: the state an atomic.Value holds, read.
        .member => |access| return if (try atomicLoad(c, file, access) != .no) access else null,
        .callee => |call| return if (try atomicLoad(c, file, at) != .no) call else null,
        .switched => |chosen| {
            for (tree.fullSwitch(chosen).?.ast.cases) |case| if (!try otherPlace(c, file, tree.fullSwitchCase(case).?.ast.target_expr, state)) return chosen; // unreachable: a switch's operand is a switch's, its cases are cases
            return null;
        },
        .tested => |branch| {
            const full = tree.fullIf(branch) orelse return null;
            if (full.payload_token != null) return null;
            const otherwise = full.ast.else_expr.unwrap() orelse return branch;
            return if (!try otherPlace(c, file, full.ast.then_expr, state) or !try otherPlace(c, file, otherwise, state)) branch else null;
        },
        else => return null,
    }
}

/// Whether the member read `access` is std's `atomic.Value` `load`, by its declaration;
/// unknown where it does not resolve.
fn atomicLoad(c: *Context, file: Project.FileId, access: Ast.Node.Index) Context.Error!Facts.Is {
    return switch (try c.facts.definition(file, access)) {
        .decl => |decl| stdAmong(c, decl, &.{"atomic.Value.load"}),
        .none => .no,
        .unknown => |why| .{ .unknown = why },
    };
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
fn destructured(c: *Context, file: Project.FileId, tuple: Ast.Node.Index, position: usize) Context.Error!?Ast.Node.Index {
    const statement = switch (try Facts.accesses.useOf(c.facts, file, tuple)) {
        .destructured => |statement| statement,
        else => return null,
    };
    const full = c.project.at(file).file.tree.assignDestructure(statement);
    return if (position < full.ast.variables.len) full.ast.variables[position] else null;
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
            .address => if (site.reach == .holder or (hold == .tagged and payloadCapture(tree, site.node))) continue else if (hold == .atomic) switch (try atomicWrite(c, site.file, site.target orelse site.node)) {
                .read => continue,
                .write => |value| value,
                .unknown => null,
            } else null,
            .set => if (site.value) |value| written: {
                // `undefined` gives it no state: reading it after is illegal.
                if (try undefinedValue(c, site.file, value)) continue;
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

/// Whether `node` is `undefined` (`Facts.literalOf`).
fn undefinedValue(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const literal = (try c.facts.literalOf(file, node)) orelse return false;
    return literal == .undefined;
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
    const inner = Facts.ungrouped(tree, node);
    if (inner != node) return madeValue(c, file, inner, state, depth + 1);
    if (tree.nodeTag(node) == .@"try") return madeValue(c, file, tree.nodeData(node).node, state, depth + 1);
    if (Facts.isBuiltin(tree, node, "@as")) {
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        return if (args.len == 2) madeValue(c, file, args[1], state, depth + 1) else true;
    }
    // A declaration of a type or a namespace (`Job.empty`) is a constant; a field is a place.
    if (try Facts.accesses.memberRead(c.facts, file, node)) |step| return step.holder.? == .container; // unreachable: a member's step has its holder's value
    switch (try c.facts.definition(file, node)) {
        .decl => |decl| {
            if (decl.file != file) return true;
            const record = model.declarations[@backingInt(decl.index)];
            if (record.kind != .variable) return false;
            const variable = tree.fullVarDecl(record.node) orelse return true;
            // A constant's value is made where it is declared; a var's may be copied in later.
            if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
            return madeValue(c, file, variable.ast.init_node.unwrap() orelse return true, state, depth + 1);
        },
        .unknown => return true,
        .none => {},
    }
    // Another place's value: `p.*`, an element, a payload.
    return switch ((try Facts.accesses.pathOf(c.facts, file, node)).steps[0].kind) {
        .deref, .index, .unwrap => false,
        else => true,
    };
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
    var at = target orelse return false;
    var position = std.mem.findScalar(Ast.Node.Index, args, at);
    // Through its address and parentheses, to the argument.
    while (position == null) {
        at = switch (try Facts.accesses.useOf(c.facts, call.file, at)) {
            .address => |address| address,
            .carried => |onward| if (onward.how == .grouped) onward.into else return false,
            else => return false,
        };
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
fn atomicWrite(c: *Context, file: Project.FileId, at: Ast.Node.Index) Context.Error!union(enum) { read, write: Ast.Node.Index, unknown } {
    const tree = &c.project.at(file).file.tree;
    const node = switch (try Facts.accesses.useOf(c.facts, file, at)) {
        .member => |access| access,
        else => return .unknown,
    };
    const operation = switch (try c.facts.definition(file, node)) {
        .decl => |decl| decl,
        .none, .unknown => return .unknown,
    };
    if (try stdAmong(c, operation, &.{"atomic.Value.load"}) == .yes) return .read;
    const call_node = switch (try Facts.accesses.useOf(c.facts, file, node)) {
        .callee => |call| call,
        else => return .unknown,
    };
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, call_node) orelse return .unknown;
    if (try stdAmong(c, operation, &.{ "atomic.Value.store", "atomic.Value.swap" }) == .yes) return if (call.ast.params.len > 0) .{ .write = call.ast.params[0] } else .unknown;
    return .{ .write = call_node };
}

/// Whether the field read at `node` is a switch's operand, read past `orelse`'s left side, `.?`,
/// `.*`, `&`, parentheses, `@as`, `@atomicLoad` and an atomic.Value's `load`; an integer's
/// (`integral`) only where it is made its enum on the way (`@enumFromInt`, `@fromBackingInt`)
/// or the switch's prongs are literals, as a state's are.
fn switchedOn(c: *Context, file: Project.FileId, node: Ast.Node.Index, hold: StateHold) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    var at = node;
    var converted = hold != .integral;
    while (true) switch (try Facts.accesses.useOf(c.facts, file, at)) {
        .switched => |chosen| return converted or try literalProngs(c, file, tree.fullSwitch(chosen).?), // unreachable: what is switched on is a switch's
        .carried => |onward| switch (onward.how) {
            .unwrapped, .grouped, .payload => at = onward.into,
            else => return false,
        },
        .address, .dereferenced => |whole| at = whole,
        // `x.state.load(order)`: the state an atomic.Value holds, loaded.
        .member => |access| {
            if (hold != .atomic or try atomicLoad(c, file, access) == .no) return false;
            at = access;
        },
        .callee => |call| {
            if (try atomicLoad(c, file, at) == .no) return false;
            at = call;
        },
        .builtin_argument => |argument| {
            const name = Facts.builtinName(tree, argument.call) orelse return false;
            if (std.mem.eql(u8, name, "@enumFromInt") or std.mem.eql(u8, name, "@fromBackingInt")) {
                converted = true;
            } else if (std.mem.eql(u8, name, "@atomicLoad")) {
                // `@atomicLoad(T, &x.state, order)`: the state, loaded.
                var args_buffer: [2]Ast.Node.Index = undefined;
                if (Facts.builtinArgs(tree, argument.call, &args_buffer).len != 3 or argument.position != 1) return false;
            } else if (!std.mem.eql(u8, name, "@as")) return false;
            at = argument.call;
        },
        else => return false,
    };
}

/// Whether a switch's prongs are literals (`0 =>`, `'a' =>`, `1...3 =>`), as a state coded as
/// an integer's are.
fn literalProngs(c: *Context, file: Project.FileId, choice: Ast.full.Switch) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    var any = false;
    for (choice.ast.cases) |case_node| {
        const case = tree.fullSwitchCase(case_node).?; // unreachable: a switch's cases are cases.
        for (case.ast.values) |value| {
            // A range's first bound (`1...3`).
            const item = if (tree.nodeTag(value) == .switch_range) tree.nodeData(value).node_and_node[0] else value;
            const literal = if (try c.facts.literalOf(file, item)) |known| known == .number or known == .char else false;
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
        // To its root through members, elements, slices, `.?`, `.*` and parentheses
        // (`Facts.accesses.pathOf`), then through `&`.
        const path = try Facts.accesses.pathOf(c.facts, file, at);
        const root = path.steps[path.steps.len - 1].node;
        if (try addressOperand(c, file, root)) |place| {
            at = place;
            continue;
        }
        switch (path.root) {
            .decl => |decl| {
                if (decl.file != file) return .other;
                const d = decl.index;
                const record = model.declarations[@backingInt(d)];
                if (enclosingFunction(model, tree, record.node) != function and record.node != function) return .other;
                switch (record.kind) {
                    .parameter => return if (parameterPosition(tree, model, function, d)) |position| .{ .parameter = position } else .other,
                    .capture => at = capturedBy(tree, model, record) orelse return .other,
                    .variable => {
                        const variable = tree.fullVarDecl(record.node) orelse return .other;
                        const by_value = switch (try c.facts.resolve(file, root)) {
                            .instance, .array, .optional, .literal, .reified => true,
                            // Its type as written where its value does not resolve.
                            .unknown => if (variable.ast.type_node.unwrap()) |written| tree.fullPtrType(written) == null and Facts.accesses.formOf(tree.nodeTag(written)) != .optional_type else false,
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
            .unknown => return .other,
            .none => {
                // A call's result held by pointer (`c.project.at(file)`): what its receiver holds.
                var buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buffer, root) orelse return .other;
                const method = (try Facts.accesses.memberRead(c.facts, file, call.ast.fn_expr)) orelse return .other;
                at = method.receiver.?; // unreachable: a member's step has its holder
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
        return try Model.identifier(c.allocator, tree.tokenSlice(Model.initName(tree, literal.ast.fields[0]) orelse return null));
    }
    const inner = Facts.ungrouped(tree, node);
    if (inner != node) return fixedState(c, file, inner);
    if (try c.facts.literalOf(file, node)) |literal| return switch (literal) {
        .enum_literal => |name| name,
        .number, .char => tree.tokenSlice(tree.nodeMainToken(node)),
        else => null,
    };
    // A member of an enum type (`Phase.done`).
    if (try Facts.accesses.memberRead(c.facts, file, node)) |step| {
        const held = step.holder.?; // unreachable: a member's step has its holder's value
        if (held != .container or !isEnum(c, held.container)) return null;
        return step.name;
    }
    if (Facts.isBuiltin(tree, node, "@backingInt") or Facts.isBuiltin(tree, node, "@intFromEnum")) {
        var args: [2]Ast.Node.Index = undefined;
        const operands = Facts.builtinArgs(tree, node, &args);
        return if (operands.len == 1) fixedState(c, file, operands[0]) else null;
    }
    return null;
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
    // Each store of one value into a field (`s.f = v`, a destructure's element).
    for (try Facts.accesses.storesIn(c.facts, c.file)) |site| {
        if (site.kind != .set) continue;
        const node = site.node;
        const value = site.value orelse continue;
        if (try Facts.accesses.memberRead(c.facts, c.file, site.target orelse continue) == null) continue;
        if (c.inTest(tree.nodeMainToken(node)) or !Danger.atRuntime(c, node)) continue;
        const what = (try borrow(c, tree, namespaces, value)) orelse continue;
        if (try settled(c, node, value)) continue;
        try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("a borrow of a std container's storage ({s}) stored in a field: the next growth moves it; aegis handle keys or scope references stay valid", .{what}));
    }
}

/// What borrow of std container storage `node` is, if it is one.
fn borrow(c: *Context, tree: *const Ast, namespaces: []const ?Facts.Container, node: Ast.Node.Index) Context.Error!?[]const u8 {
    const inner = Facts.ungrouped(tree, node);
    if (inner != node) return borrow(c, tree, namespaces, inner);
    // An element's address (`&list.items[i]`): of what the element is of.
    if (try addressOperand(c, c.file, node)) |place| {
        const path = try Facts.accesses.pathOf(c.facts, c.file, place);
        if (path.steps[0].kind != .index) return null;
        return borrow(c, tree, namespaces, path.steps[1].node);
    }
    if (try Facts.accesses.memberRead(c.facts, c.file, node)) |step| {
        if (!(try readsOwn(c, c.file, node, "items") orelse false)) return null;
        return if (try ofStd(c, namespaces, step.receiver.?)) "items" else null; // unreachable: a member's step has its holder
    }
    // A payload, a slice: of what holds it.
    const path = try Facts.accesses.pathOf(c.facts, c.file, node);
    switch (path.steps[0].kind) {
        .unwrap, .slice => return borrow(c, tree, namespaces, path.steps[1].node),
        else => {},
    }
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    const method = (try Facts.accesses.memberRead(c.facts, c.file, call.ast.fn_expr)) orelse return null;
    for ([_][]const u8{ "getPtr", "getEntry", "getKeyPtr", "keys", "values" }) |each| if (try readsOwn(c, c.file, call.ast.fn_expr, each) orelse false) {
        return if (try ofStd(c, namespaces, method.receiver.?)) each else null; // unreachable: a member's step has its holder
    };
    return null;
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
    // Down to the member the borrow is read through: `items`, or the method called.
    var at = value;
    const access = while (true) {
        if (try addressOperand(c, c.file, at)) |place| {
            at = place;
            continue;
        }
        if (try Facts.accesses.memberRead(c.facts, c.file, at)) |step| break step;
        const path = try Facts.accesses.pathOf(c.facts, c.file, at);
        if (path.steps.len > 1) switch (path.steps[0].kind) {
            // A payload, an element, a slice: of what holds it.
            .unwrap, .index, .slice => {
                at = path.steps[1].node;
                continue;
            },
            else => return false,
        };
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, Facts.ungrouped(tree, at)) orelse return false;
        break (try Facts.accesses.memberRead(c.facts, c.file, call.ast.fn_expr)) orelse return false;
    };
    const receiver = access.receiver.?; // unreachable: a member's step has its holder
    if (try Facts.accesses.memberRead(c.facts, c.file, receiver) != null) return false;
    const local = switch (try c.facts.definition(c.file, receiver)) {
        .decl => |decl| if (decl.file == c.file) decl.index else return false,
        .none, .unknown => return false,
    };
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
    for (model.references) |reference| {
        if (reference.declaration != local) continue;
        const node = reference.node;
        if (tree.nodeMainToken(node) > end) return false;
        const parent = switch (try Facts.accesses.useOf(c.facts, c.file, node)) {
            .member => |member| member,
            else => return false,
        };
        // A list freed at all, wherever the free is written (a `defer` before the store runs
        // after it), leaves the borrow pointing at freed memory.
        // By the declaration the list's own type gives each name; one not shown may free.
        for ([_][]const u8{ "deinit", "clearAndFree", "shrinkAndFree", "toOwnedSlice", "toOwnedSliceSentinel", "moveToUnmanaged", "clearRetainingCapacity" }) |frees| {
            if (try readsOwn(c, c.file, parent, frees) orelse true) return false;
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

/// Whether the member read `node` is the declaration its holder's own type gives `name` (an
/// `own.Owned`'s `borrow`, a std list's `items`): what Zig resolves the name it spells to in the
/// type its holder is, through pointers and optionals. Null where the holder's type does not
/// resolve to one container (a choice per build among them), or the spelled name to nothing.
fn readsOwn(c: *Context, file: Project.FileId, node: Ast.Node.Index, name: []const u8) Context.Error!?bool {
    const step = (try Facts.accesses.memberRead(c.facts, file, node)) orelse return false;
    const holder = byPointer(step.holder orelse return null) orelse return null;
    const declared = c.facts.member(holder, name) orelse return false;
    const named = c.facts.member(holder, step.name orelse return null) orelse return null;
    return std.meta.eql(named, declared);
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
