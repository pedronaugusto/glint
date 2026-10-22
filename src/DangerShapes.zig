//! The danger rules read from the shapes of declarations and statements (designs/aegis.md §7):
//! a std resource without its one owner (A015), two identifying integers of one type meeting
//! in one signature (A016), an enum state written from several places and switched on (A017),
//! a borrow of a std container's storage kept in a field (A014), and a local read while it is
//! still `undefined` (A019).
const std = @import("std");
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Danger = @import("Danger.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;

/// A015: a std resource held by value in a field, or returned by the program's own function,
/// outside aegis's `own.Owned`.
pub fn ownership(c: *Context, rule: Rule) Context.Error!void {
    const paths = [_][]const u8{ "Io.File", "Io.Dir", "Io.net.Stream", "Io.net.Server", "process.Child" };
    const resources = try containersOf(c, rule, &paths);
    if (resources.len == 0) return;
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    for (model.declarations) |decl| {
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
        const what = if (decl.kind == .field) "field" else "function";
        const how = if (decl.kind == .field) "holds" else "returns";
        try c.at(rule, decl.token, try c.allocator.print("{s} '{s}' {s} a std.{s} by value: aegis own.Owned names its one owner and checks it is released once", .{ what, decl.name, how, paths[which] }));
    }
}

/// A016: two or more identifying integers of one type meeting in one public signature or one
/// public struct, where nothing keeps one from standing for the other.
pub fn identity(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
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
    for (model.scopes, 0..) |scope, s| {
        if (scope.kind != .container and scope.kind != .file) continue;
        if (scope.kind == .container and !publicContainer(tree, model, scope.node)) continue;
        var names: std.ArrayList(Ast.TokenIndex) = .empty;
        var types: std.ArrayList([]const u8) = .empty;
        for (model.declarations) |decl| {
            if (decl.kind != .field or decl.scope != s or c.inTest(decl.token) or !identifies(decl.name)) continue;
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
        const tail = name[name.len - word.len ..];
        const before = name[name.len - word.len - 1];
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
    const parent = model.node_parents[@backingInt(node)] orelse return true; // safe: a node index indexes its own tree's parent table.
    const variable = tree.fullVarDecl(parent) orelse return false;
    return variable.visib_token != null;
}

/// A017: an enum state written by two or more functions and switched on, a state machine kept
/// by hand: nothing says which transitions are allowed.
pub fn stateMachines(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    for (model.declarations) |decl| {
        if (decl.kind != .field or c.inTest(decl.token)) continue;
        const written = (tree.fullContainerField(decl.node) orelse continue).ast.type_expr.unwrap() orelse continue;
        const state = byValue(try c.facts.resolve(c.file, written)) orelse continue;
        if (!isEnum(c, state)) continue;
        const holder: Facts.Container = .{ .file = c.file, .scope = decl.scope };
        var writers: std.ArrayList(Facts.Key) = .empty;
        var switched = false;
        for (try c.facts.memberUses(decl.name)) |use| {
            const use_tree = &c.project.files[use.file.raw()].tree;
            const use_model = &c.project.models[use.file.raw()];
            const receiver = try c.facts.resolve(use.file, use_tree.nodeData(use.node).node_and_token[0]);
            const owner = byPointer(receiver) orelse continue;
            if (owner.file.raw() != holder.file.raw() or owner.scope != holder.scope) continue;
            const parent = use_model.node_parents[@backingInt(use.node)] orelse continue; // safe: a node index indexes its own tree's parent table.
            if (use_tree.nodeTag(parent) == .assign and use_tree.nodeData(parent).node_and_node[0] == use.node) {
                const function = enclosingFunction(use_model, use_tree, parent) orelse continue;
                for (writers.items) |seen| {
                    if (seen.file.raw() == use.file.raw() and seen.node == function) break;
                } else try writers.append(c.allocator, .{ .file = use.file, .node = function });
            }
            if (use_tree.fullSwitch(parent)) |s| switched = switched or s.ast.condition == use.node;
        }
        if (writers.items.len >= 2 and switched) try c.at(rule, decl.token, try c.allocator.print("'{s}' is a state machine kept by hand: written in {d} functions and switched on; aegis state.Machine states which transitions there are", .{ decl.name, writers.items.len }));
    }
}

fn isEnum(c: *Context, value: Facts.Container) bool {
    const tree = &c.project.files[value.file.raw()].tree;
    const node = c.project.models[value.file.raw()].scopes[value.scope].node;
    if (node == .root) return false;
    return tree.tokenTag(tree.nodeMainToken(node)) == .keyword_enum;
}

fn enclosingFunction(model: *const Model, tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) { // safe: a node index indexes its own tree's parent table.
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
    const tree = &c.project.files[c.file.raw()].tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .assign) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: the AST's node table indexes fit u32.
        const target, const value = tree.nodeData(node).node_and_node;
        if (tree.nodeTag(target) != .field_access or c.inTest(tree.nodeMainToken(node)) or !Danger.atRuntime(c, node)) continue;
        const what = (try borrow(c, tree, namespaces, value)) orelse continue;
        try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("a borrow of a std container's storage ({s}) stored in a field: the next growth moves it; aegis handle keys or scope references stay valid", .{what}));
    }
}

/// What borrow of std container storage `node` is, if it is one.
fn borrow(c: *Context, tree: *const Ast, namespaces: []const Facts.Container, node: Ast.Node.Index) Context.Error!?[]const u8 {
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

/// Whether a value is a container declared in one of std's container namespaces.
fn ofStd(c: *Context, namespaces: []const Facts.Container, node: Ast.Node.Index) Context.Error!bool {
    const held = byPointer(try c.facts.resolve(c.file, node)) orelse return false;
    for (namespaces) |namespace| if (held.file.raw() == namespace.file.raw()) return true;
    return false;
}

/// A019's `undefined` reads: a `var` declared `undefined` in a function's body, read before every
/// path to the read writes it. A write is an assignment to it or into it, its address taken or
/// a part of it sliced (what a call fills through the pointer it is given is that call's
/// contract), or a method called on it; a path through a loop or a branch that writes it on some
/// paths only ends the walk, never a guess.
pub fn undefinedReads(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .variable or c.inTest(decl.token)) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_var) continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        if (tree.nodeTag(init) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init)), "undefined")) continue;
        if (!Danger.atRuntime(c, decl.node)) continue;
        const block = model.node_parents[@backingInt(decl.node)] orelse continue; // safe: a node index indexes its own tree's parent table.
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse continue;
        var walk: Walk = .{ .c = c, .tree = tree, .model = model, .local = @intCast(d) }; // safe: a file's declaration table indexes fit u32.
        try walk.collect();
        const start = std.mem.findScalar(Ast.Node.Index, statements, decl.node) orelse continue;
        _ = try walk.sequence(statements[start + 1 ..], .unwritten);
        if (walk.read) |token| try c.at(rule, token, try c.allocator.print("'{s}' is read here while still undefined on a path from its declaration: a read of undefined memory, which no build checks", .{decl.name}));
    }
}

const State = enum { unwritten, written, done };

const Walk = struct {
    c: *Context,
    tree: *const Ast,
    model: *const Model,
    local: u32,
    /// The identifiers that name the local, in source order.
    mentions: std.ArrayList(Ast.Node.Index) = .empty,
    read: ?Ast.TokenIndex = null,

    fn collect(w: *Walk) Context.Error!void {
        for (w.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: the AST's node table indexes fit u32.
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
            // The body runs first with the local unwritten; what it leaves holds on some paths only.
            const body = try w.statement(loop.ast.then_expr, after);
            return if (body == .unwritten) after else .done;
        }
        if (tree.fullFor(node)) |loop| {
            for (loop.ast.inputs) |input| if (try w.statement(input, state) != .unwritten) return .done;
            const body = try w.statement(loop.ast.then_expr, state);
            return if (body == .unwritten) state else .done;
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
            const use = w.classify(mention);
            if (earliest == null or use.key < earliest.?.key) earliest = .{ .key = use.key, .write = use.write, .token = token };
        }
        const found = earliest orelse return .unwritten;
        if (found.write) return .written;
        w.read = found.token;
        return .done;
    }

    const Use = struct { key: Ast.TokenIndex, write: bool };

    /// Whether a mention writes the local, and where it falls in evaluation order.
    fn classify(w: *Walk, mention: Ast.Node.Index) Use {
        const tree = w.tree;
        var at = mention;
        while (w.model.node_parents[@backingInt(at)]) |parent| : (at = parent) { // safe: a node index indexes its own tree's parent table.
            switch (tree.nodeTag(parent)) {
                .field_access, .array_access => {
                    if (tree.nodeData(parent).node_and_token[0] != at and tree.nodeTag(parent) == .field_access) break;
                    if (tree.nodeTag(parent) == .array_access and tree.nodeData(parent).node_and_node[0] != at) break;
                    // A method called on it may write through its receiver.
                    if (tree.nodeTag(parent) == .field_access) {
                        const grand = w.model.node_parents[@backingInt(parent)] orelse break; // safe: a node index indexes its own tree's parent table.
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

    fn mentioned(w: *Walk, node: Ast.Node.Index) bool {
        const first = w.tree.firstToken(node);
        const last = w.tree.lastToken(node);
        for (w.mentions.items) |mention| {
            const token = w.tree.nodeMainToken(mention);
            if (token >= first and token <= last) return true;
        }
        return false;
    }
};

fn merge(a: State, b: State) State {
    if (a == .done or b == .done) return .done;
    if (a == .written and b == .written) return .written;
    if (a == .unwritten and b == .unwritten) return .unwritten;
    // Written on some paths only: what follows is not read with a guess.
    return .done;
}

/// The containers std's `paths` name (a namespace's file, a type), each resolved once.
fn containersOf(c: *Context, rule: Rule, paths: []const []const u8) Context.Error![]const Facts.Container {
    const targets = try c.allocator.alloc(Governed.Target, paths.len);
    const indexes = try c.allocator.alloc(usize, paths.len);
    for (paths, targets, indexes, 0..) |path, *target, *index, i| {
        target.* = .{ .source = "std", .declaration = path };
        index.* = i;
    }
    var out: std.ArrayList(Facts.Container) = .empty;
    for (try Governed.resolve(c, rule, targets, indexes)) |found| {
        var container: ?Facts.Container = null;
        for (found.decls) |decl| {
            const value = try c.facts.declaration((try c.facts.origin(decl)) orelse decl);
            if (value == .container) container = value.container;
        }
        // Kept in the order of `paths`, an unresolved one as a container no value has.
        try out.append(c.allocator, container orelse .{ .file = c.file, .scope = std.math.maxInt(u32) });
    }
    return out.items;
}

fn find(containers: []const Facts.Container, held: Facts.Container) ?usize {
    for (containers, 0..) |k, i| if (k.file.raw() == held.file.raw() and k.scope == held.scope) return i;
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
