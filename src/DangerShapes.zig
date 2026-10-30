//! The danger rules read from the shapes of declarations and statements (designs/aegis.md §7):
//! a std resource without its one owner (A015), two identifying integers of one type meeting
//! in one signature (A016), an enum state its holder moves by hand on its own value (A017),
//! a borrow of a std container's storage kept in a field (A014), and a local read while it is
//! still `undefined` (A019).
const std = @import("std");
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Contract = @import("AegisContract.zig");
const Danger = @import("Danger.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;

/// A015: a std resource held by value in a field its file releases (`close`, `deinit`), or
/// returned by the program's own function, outside aegis's `own.Owned`. A field nothing in its
/// file releases borrows a handle its caller owns (an options or context struct), and a function
/// each of whose returns reads what is already held hands over no owner (`views`).
pub fn ownership(c: *Context, rule: Rule) Context.Error!void {
    const paths = [_][]const u8{ "Io.File", "Io.Dir", "Io.net.Stream", "Io.net.Server", "process.Child" };
    const resources = try containersOf(c, rule, &paths);
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
        const held = byValue(try c.facts.resolve(c.file, written)) orelse continue;
        const which = find(resources, held) orelse continue;
        if (decl.kind == .field and !releasedAnywhere(c, decl.name)) continue;
        if (decl.kind == .function and try views(c, resources, decl)) continue;
        if (decl.kind == .function) {
            if (!looked) {
                vtable = (try containersOf(c, rule, &.{"Io.VTable"}))[0];
                looked = true;
            }
            if (try implements(c, @fromBackingInt(@intCast(index)), vtable)) continue;
        }
        const what = if (decl.kind == .field) "field" else "function";
        const how = if (decl.kind == .field) "holds" else "returns";
        try c.at(rule, decl.token, try c.allocator.print("{s} '{s}' {s} a std.{s} by value: aegis own.Owned names its one owner and checks it is released once", .{ what, decl.name, how, paths[which] }));
    }
}

/// Whether every return of a function reads a resource someone already holds, so it hands over
/// no owner: a parameter passed back, a field read (the field's declaration is where its owner is
/// judged) of something itself held, a declared constant, std's process-wide `stdin`, `stdout` or
/// `stderr`, which nobody closes, or a literal naming a handle it was given (`.{ .handle = handle
/// }`). A variable (a field moved out first) or what a call made is an owner handed over.
fn views(c: *Context, resources: []const ?Facts.Container, decl: Model.Declaration) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
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
        if (!try viewed(c, resources, value, 0)) return false;
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
        if (!source.input.selected) continue;
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

fn viewed(c: *Context, resources: []const ?Facts.Container, node: Ast.Node.Index, depth: u8) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    if (depth == 16) return false;
    const next = depth + 1;
    switch (tree.nodeTag(node)) {
        .grouped_expression => return viewed(c, resources, tree.nodeData(node).node_and_token[0], next),
        .unwrap_optional => return viewed(c, resources, tree.nodeData(node).node_and_token[0], next),
        .array_access => return viewed(c, resources, tree.nodeData(node).node_and_node[0], next),
        .@"orelse" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return try viewed(c, resources, lhs, next) and try viewed(c, resources, rhs, next);
        },
        .field_access => {
            var root = node;
            while (tree.nodeTag(root) == .field_access or tree.nodeTag(root) == .unwrap_optional or tree.nodeTag(root) == .array_access) root = switch (tree.nodeTag(root)) {
                .array_access => tree.nodeData(root).node_and_node[0],
                else => tree.nodeData(root).node_and_token[0],
            };
            return tree.nodeTag(root) == .identifier and try viewed(c, resources, root, next);
        },
        .identifier => {
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "null")) return true;
            const reference = model.reference(node) orelse return false;
            const d = reference.declaration orelse return false;
            const record = model.declarations[@backingInt(d)];
            if (record.kind == .parameter) return true;
            // A capture holds what it binds: a view where that is one (an owner a call made,
            // unwrapped, is handed over).
            if (record.kind == .capture) {
                const bound: ?Ast.Node.Index = if (tree.fullIf(record.node)) |branch| branch.ast.cond_expr else if (tree.fullWhile(record.node)) |loop| loop.ast.cond_expr else if (tree.fullFor(record.node)) |loop| (if (loop.ast.inputs.len == 1) loop.ast.inputs[0] else null) else null;
                return viewed(c, resources, bound orelse return false, next);
            }
            if (record.kind != .variable) return false;
            const variable = tree.fullVarDecl(record.node) orelse return false;
            if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
            // A declared constant, or a local one made from what is already held.
            return switch (model.scopes[@backingInt(record.scope)].kind) {
                .file, .container => true,
                else => try viewed(c, resources, variable.ast.init_node.unwrap() orelse return false, next),
            };
        },
        .@"switch", .switch_comma => {
            const full = tree.fullSwitch(node).?;
            for (full.ast.cases) |case| if (!try viewed(c, resources, tree.fullSwitchCase(case).?.ast.target_expr, next)) return false;
            return true;
        },
        else => {
            if (tree.fullIf(node)) |branch| {
                const otherwise = branch.ast.else_expr.unwrap() orelse return false;
                return try viewed(c, resources, branch.ast.then_expr, next) and try viewed(c, resources, otherwise, next);
            }
            var buffer: [1]Ast.Node.Index = undefined;
            if (tree.fullCall(&buffer, node)) |call| {
                if (call.ast.params.len != 0) return false;
                const callee = switch (try c.facts.resolve(c.file, call.ast.fn_expr)) {
                    .function => |decl| (try c.facts.origin(decl)) orelse decl,
                    else => return false,
                };
                for ([_][]const u8{ "Io.File.stdin", "Io.File.stdout", "Io.File.stderr" }) |standard| {
                    for ((try Governed.declarations(c, "std", standard)) orelse &.{}) |decl| {
                        if (std.meta.eql((try c.facts.origin(decl)) orelse decl, callee)) return true;
                    }
                }
                return false;
            }
            var init_buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullStructInit(&init_buffer, node)) |literal| {
                // A std handle made from one it is given: the literal of a std resource type.
                const made = byValue(try c.facts.literalType(c.file, node)) orelse return false;
                if (find(resources, made) == null) return false;
                for (literal.ast.fields) |value| {
                    if (!std.mem.eql(u8, tree.tokenSlice(Model.initName(tree, value) orelse continue), "handle")) continue;
                    return viewed(c, resources, value, next);
                }
                return false;
            }
            return false;
        },
    }
}

/// Whether any of the program's files releases a field named `name`: wherever the owner is
/// released, the field holds one.
fn releasedAnywhere(c: *Context, name: []const u8) bool {
    for (c.project.sources) |*source| {
        if (source.input.selected and released(&source.file.tree, name)) return true;
    }
    return false;
}

/// Whether the file releases the field `name`: `x.name.close(`, `deinit(`, `kill(` or `wait(`,
/// through an optional's `.?` too, or through a capture of it (`if (x.name) |f| f.close(`).
/// A local of the same name is not the field.
fn released(tree: *const Ast, name: []const u8) bool {
    const tags = tree.tokens.items(.tag);
    var i: usize = 1;
    while (i + 2 < tags.len) : (i += 1) {
        if (tags[i] != .identifier or tags[i - 1] != .period or !std.mem.eql(u8, tree.tokenSlice(@intCast(i)), name)) continue;
        var at = i + 1;
        if (tags[at] == .period_asterisk or (tags[at] == .period and at + 1 < tags.len and tags[at + 1] == .question_mark)) at += if (tags[at] == .period) 2 else 1;
        if (at + 1 < tags.len and tags[at] == .period and tags[at + 1] == .identifier and release(tree.tokenSlice(@intCast(at + 1)))) return true;
        // `(x.name) |capture| ... capture.close(`
        if (at + 3 < tags.len and tags[at] == .r_paren and tags[at + 1] == .pipe and tags[at + 2] == .identifier and tags[at + 3] == .pipe) {
            const capture = tree.tokenSlice(@intCast(at + 2));
            var k = at + 4;
            while (k + 2 < tags.len and k < at + 16) : (k += 1) {
                if (tags[k] == .identifier and std.mem.eql(u8, tree.tokenSlice(@intCast(k)), capture) and tags[k + 1] == .period and release(tree.tokenSlice(@intCast(k + 2)))) return true;
            }
        }
    }
    return false;
}

fn release(method: []const u8) bool {
    for ([_][]const u8{ "close", "deinit", "kill", "wait" }) |name| if (std.mem.eql(u8, method, name)) return true;
    return false;
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

/// A019's `undefined` reads: a `var` declared `undefined` in a function's body, read before every
/// path to the read writes it. A write is an assignment to it or into it, its address taken or
/// a part of it sliced (what a call fills through the pointer it is given is that call's
/// contract), a method called on it, or an `asm` output bound to it (`"={eax}" (eax)`), written
/// once the `asm` has read its inputs. A branch that writes it on some paths only, and a loop
/// that may run no pass, leave it unwritten for what follows; a branch that leaves (`return`,
/// `break`, `continue`, `unreachable`) reaches nothing after it, and a `for` over a range of
/// literals runs at least once.
pub fn undefinedReads(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .variable or c.inTest(decl.token)) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_var) continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        if (tree.nodeTag(init) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init)), "undefined")) continue;
        if (!Danger.atRuntime(c, decl.node)) continue;
        const block = model.parentOf(decl.node) orelse continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse continue;
        var walk: Walk = .{ .c = c, .tree = tree, .model = model, .local = @fromBackingInt(@intCast(d)) };
        try walk.collect();
        const start = std.mem.findScalar(Ast.Node.Index, statements, decl.node) orelse continue;
        _ = try walk.sequence(statements[start + 1 ..], .unwritten);
        if (walk.read) |token| try c.at(rule, token, try c.allocator.print("'{s}' is read here while still undefined on a path from its declaration: a read of undefined memory, which no build checks", .{decl.name}));
    }
}

/// Where the walk stands: the local unwritten, written, a read found (`done`), or the path left
/// before what follows (`left`).
const State = enum { unwritten, written, done, left };

const Walk = struct {
    c: *Context,
    tree: *const Ast,
    model: *const Model,
    local: Model.Declaration.Id,
    /// The identifiers that name the local, in source order.
    mentions: std.ArrayList(Ast.Node.Index) = .empty,
    /// The `asm` outputs bound to the local, by the token naming it, with the `asm` they are in.
    outputs: std.ArrayList(struct { token: Ast.TokenIndex, asm_node: Ast.Node.Index }) = .empty,
    read: ?Ast.TokenIndex = null,

    fn collect(w: *Walk) Context.Error!void {
        const name = w.model.declarations[@backingInt(w.local)].name;
        for (w.tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (tag == .asm_output) {
                // `[a] "b" (c)` names its variable by the token before `)`; `(-> T)` returns one.
                const lhs, const rparen = w.tree.nodeData(node).opt_node_and_token;
                if (lhs != .none or !std.mem.eql(u8, w.tree.tokenSlice(rparen - 1), name)) continue;
                const asm_node = w.enclosingAsm(rparen) orelse continue;
                try w.outputs.append(w.c.allocator, .{ .token = rparen - 1, .asm_node = asm_node });
                continue;
            }
            if (tag != .identifier) continue;
            const ref = w.model.reference(node) orelse continue;
            if (ref.declaration == w.local) try w.mentions.append(w.c.allocator, node);
        }
    }

    fn sequence(w: *Walk, statements: []const Ast.Node.Index, state: State) Context.Error!State {
        var now = state;
        for (statements) |each| {
            if (now != .unwritten) return now;
            now = try w.statement(each, now);
        }
        return now;
    }

    /// The state past `node`, reading it in the order Zig evaluates it.
    fn statement(w: *Walk, node: Ast.Node.Index, state: State) Context.Error!State {
        const tree = w.tree;
        // A path that leaves reads what it leaves with first.
        switch (tree.nodeTag(node)) {
            .@"return", .@"break", .@"continue", .unreachable_literal => {
                const past = if (w.mentioned(node)) try w.simple(node) else state;
                return if (past == .done) .done else .left;
            },
            else => {},
        }
        if (!w.mentioned(node)) return state;
        switch (tree.nodeTag(node)) {
            .@"defer", .@"errdefer" => return state,
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var buffer: [2]Ast.Node.Index = undefined;
                return w.sequence(tree.blockStatements(&buffer, node).?, state);
            },
            else => {},
        }
        if (tree.fullIf(node)) |branch| {
            const after = try w.statement(branch.ast.cond_expr, state);
            if (after != .unwritten) return after;
            const then = try w.statement(branch.ast.then_expr, after);
            const otherwise = if (branch.ast.else_expr.unwrap()) |e| try w.statement(e, after) else after;
            return merge(then, otherwise);
        }
        if (tree.fullSwitch(node)) |choice| {
            const after = try w.statement(choice.ast.condition, state);
            if (after != .unwritten) return after;
            var all: ?State = null;
            for (choice.ast.cases) |case| {
                const prong = tree.fullSwitchCase(case) orelse return .done;
                const past = try w.statement(prong.ast.target_expr, after);
                all = if (all) |sofar| merge(sofar, past) else past;
            }
            return all orelse after;
        }
        if (tree.fullWhile(node)) |loop| {
            const after = try w.statement(loop.ast.cond_expr, state);
            if (after != .unwritten) return after;
            // The body runs first with the local unwritten; a loop may run no pass, so what it
            // writes holds on some paths only.
            const body = try w.statement(loop.ast.then_expr, after);
            return if (body == .done) .done else after;
        }
        if (tree.fullFor(node)) |loop| {
            for (loop.ast.inputs) |input| {
                const past = try w.statement(input, state);
                if (past != .unwritten) return past;
            }
            const body = try w.statement(loop.ast.then_expr, state);
            if (body == .done) return .done;
            // A range of literals with passes in it runs the body, and its first pass is as read.
            return if (body == .written and passes(tree, loop.ast.inputs[0])) .written else state;
        }
        return w.simple(node);
    }

    /// A statement without control flow of its own: its mentions in evaluation order, an
    /// assignment's target after its value.
    fn simple(w: *Walk, node: Ast.Node.Index) Context.Error!State {
        const first = w.tree.firstToken(node);
        const last = w.tree.lastToken(node);
        var earliest: ?struct { key: Ast.TokenIndex, write: bool, token: Ast.TokenIndex } = null;
        for (w.mentions.items) |mention| {
            const token = w.tree.nodeMainToken(mention);
            if (token < first or token > last) continue;
            const use = w.classify(mention) orelse continue;
            if (earliest == null or use.key < earliest.?.key) earliest = .{ .key = use.key, .write = use.write, .token = token };
        }
        for (w.outputs.items) |output| {
            if (output.token < first or output.token > last) continue;
            const key = w.tree.lastToken(output.asm_node);
            if (earliest == null or key < earliest.?.key) earliest = .{ .key = key, .write = true, .token = output.token };
        }
        const found = earliest orelse return .unwritten;
        if (found.write) return .written;
        w.read = found.token;
        return .done;
    }

    const Use = struct { key: Ast.TokenIndex, write: bool };

    /// Whether a mention writes the local, and where it falls in evaluation order; null where
    /// it reads none of its memory: an array's `.len`, known as the program compiles.
    fn classify(w: *Walk, mention: Ast.Node.Index) ?Use {
        const tree = w.tree;
        if (w.model.parentOf(mention)) |parent| {
            if (tree.nodeTag(parent) == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(parent).node_and_token[1]), "len") and w.array()) return null;
            // `@field(local, name) = ...` writes the field it names.
            if (builtinField(tree, parent, mention)) {
                const grand = w.model.parentOf(parent) orelse return .{ .key = tree.nodeMainToken(mention), .write = false };
                if (tree.nodeTag(grand) == .assign and tree.nodeData(grand).node_and_node[0] == parent) return .{ .key = tree.lastToken(grand), .write = true };
            }
        }
        var at = mention;
        while (w.model.parentOf(at)) |parent| : (at = parent) {
            switch (tree.nodeTag(parent)) {
                .field_access, .array_access => {
                    const base = if (tree.nodeTag(parent) == .field_access) tree.nodeData(parent).node_and_token[0] else tree.nodeData(parent).node_and_node[0];
                    if (base != at) break;
                    // A method called on it may write through its receiver.
                    if (tree.nodeTag(parent) == .field_access) {
                        const grand = w.model.parentOf(parent) orelse break;
                        var buffer: [1]Ast.Node.Index = undefined;
                        if (tree.fullCall(&buffer, grand)) |call| if (call.ast.fn_expr == parent) return .{ .key = tree.nodeMainToken(mention), .write = true };
                    }
                    continue;
                },
                .address_of => return .{ .key = tree.nodeMainToken(mention), .write = true },
                .slice_open, .slice, .slice_sentinel => {
                    if ((tree.fullSlice(parent) orelse break).ast.sliced == at) return .{ .key = tree.nodeMainToken(mention), .write = true };
                    break;
                },
                .assign => {
                    if (tree.nodeData(parent).node_and_node[0] == at) return .{ .key = tree.lastToken(parent), .write = true };
                    break;
                },
                else => break,
            }
        }
        return .{ .key = tree.nodeMainToken(mention), .write = false };
    }

    /// Whether the local is declared an array, whose length its type holds.
    fn array(w: *const Walk) bool {
        const variable = w.tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return false;
        const kind = variable.ast.type_node.unwrap() orelse return false;
        return switch (w.tree.nodeTag(kind)) {
            .array_type, .array_type_sentinel => true,
            else => false,
        };
    }

    fn builtinField(tree: *const Ast, node: Ast.Node.Index, operand: Ast.Node.Index) bool {
        switch (tree.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma => {},
            else => return false,
        }
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field")) return false;
        const first = tree.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse return false;
        return first == operand;
    }

    /// The innermost `asm` expression whose tokens hold `token`.
    fn enclosingAsm(w: *const Walk, token: Ast.TokenIndex) ?Ast.Node.Index {
        var found: ?Ast.Node.Index = null;
        for (w.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .@"asm") continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (token < w.tree.firstToken(node) or token > w.tree.lastToken(node)) continue;
            if (found == null or w.tree.firstToken(node) > w.tree.firstToken(found.?)) found = node;
        }
        return found;
    }

    fn mentioned(w: *Walk, node: Ast.Node.Index) bool {
        const first = w.tree.firstToken(node);
        const last = w.tree.lastToken(node);
        for (w.outputs.items) |output| if (output.token >= first and output.token <= last) return true;
        for (w.mentions.items) |mention| {
            const token = w.tree.nodeMainToken(mention);
            if (token >= first and token <= last) return true;
        }
        return false;
    }
};

fn merge(a: State, b: State) State {
    if (a == .done or b == .done) return .done;
    // A path that left reaches nothing after the branch.
    if (a == .left) return b;
    if (b == .left) return a;
    if (a == .written and b == .written) return .written;
    // Written on some paths only: a read that follows may read it undefined.
    return .unwritten;
}

/// Whether a `for` input is a range of literals with a pass in it (`0..2`).
fn passes(tree: *const Ast, input: Ast.Node.Index) bool {
    if (tree.nodeTag(input) != .for_range) return false;
    const start, const end = tree.nodeData(input).node_and_opt_node;
    const from = literalValue(tree, start) orelse return false;
    const to = literalValue(tree, end.unwrap() orelse return false) orelse return false;
    return to > from;
}

fn literalValue(tree: *const Ast, node: Ast.Node.Index) ?u64 {
    if (tree.nodeTag(node) != .number_literal) return null;
    return switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
        .int => |value| value,
        else => null,
    };
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
