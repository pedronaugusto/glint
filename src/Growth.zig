//! E002: a pointer into a std list's or map's storage used after an operation that may move it.
//!
//! An `ArrayList`'s `items` (a slice of them, an element's address), the element `addOne` gives,
//! a hash map's `getPtr`, `getEntry` or `getOrPut` result, its iterators and its `keys()` and
//! `values()` point into storage the container owns. Growing it (`append`, `insert`,
//! `ensureTotalCapacity`, `resize`, `put`, `getOrPut`), giving it away (`toOwnedSlice`) or
//! freeing it (`clearAndFree`, `deinit`) may move or free that storage, after which the pointer
//! dangles. Zig's safety checks do not catch the use; std's `lockPointers` does where a
//! program asks.
//!
//! A heuristic (designs/glint.md §6), reported. The borrow is a local its declaration
//! initializes from the container, named by a path (`list`, `self.list`); the operation is a
//! call on the same path in a later statement of the same block, outside deferred code, any
//! branch that never falls through and the `return` or `break` that ends a path with it; the use is a reference to the local in a statement after
//! that, or anywhere in a loop that runs the operation again. Taking the borrow again
//! (`b = list.items`) in between, an element copied by value, and the operations that never
//! reallocate (`*AssumeCapacity`, `*Bounded`) are no hits. The container must resolve to std's:
//! one that does not resolve leaves the site undecided. A clean run never certifies lifetimes.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Model = @import("Model.zig");
const Ast = std.zig.Ast;

/// Calls on a container whose result points into its storage.
const borrowing = [_][]const u8{
    "addOne",                  "addOneAssumeCapacity", "addOneBounded",                "addManyAsArray",                "addManyAsArrayAssumeCapacity",
    "addManyAsArrayBounded",   "addManyAsSlice",       "addManyAsSliceAssumeCapacity", "addManyAsSliceBounded",         "addManyAt",
    "addManyAtAssumeCapacity", "addManyAtBounded",     "allocatedSlice",               "unusedCapacitySlice",           "getPtr",
    "getPtrAdapted",           "getKeyPtr",            "getKeyPtrAdapted",             "getEntry",                      "getEntryAdapted",
    "getOrPut",                "getOrPutAdapted",      "getOrPutAssumeCapacity",       "getOrPutAssumeCapacityAdapted", "getOrPutValue",
    "iterator",                "keyIterator",          "valueIterator",                "keys",                          "values",
};

/// Calls on a container that may reallocate, hand over or free its storage.
const moving = [_][]const u8{
    "append",          "appendSlice",          "appendUnalignedSlice", "appendNTimes",               "addOne",
    "addManyAsArray",  "addManyAsSlice",       "addManyAt",            "insert",                     "insertSlice",
    "replaceRange",    "resize",               "ensureTotalCapacity",  "ensureTotalCapacityPrecise", "ensureUnusedCapacity",
    "shrinkAndFree",   "shrinkAndFreePrecise", "clearAndFree",         "toOwnedSlice",               "toOwnedSliceSentinel",
    "print",           "deinit",               "put",                  "putNoClobber",               "fetchPut",
    "fetchPutAdapted", "getOrPut",             "getOrPutAdapted",      "getOrPutValue",              "rehash",
};

/// std's files whose containers own the storage their borrows point into.
const containers = [_][]const u8{ "array_list.zig", "hash_map.zig", "array_hash_map.zig" };

pub fn check(c: *Context) Context.Error!void {
    if (!c.config.has(.E002)) return;
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    const self: Walk = .{ .c = c, .tree = tree, .model = model };
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => {},
            else => continue,
        }
        const block: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: checked AST inventory.
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse continue;
        for (statements, 0..) |stmt, at| try self.borrowed(statements, at, stmt);
    }
}

const Walk = struct {
    c: *Context,
    tree: *const Ast,
    model: *const Model,

    /// A local `stmt` declares from a container's storage, followed through the statements
    /// after it.
    fn borrowed(self: Walk, statements: []const Ast.Node.Index, at: usize, stmt: Ast.Node.Index) Context.Error!void {
        const tree = self.tree;
        const v = tree.fullVarDecl(stmt) orelse return;
        const init = v.ast.init_node.unwrap() orelse return;
        const container = self.borrowOf(init) orelse return;
        const local = for (self.model.declarations, 0..) |d, i| {
            if (d.kind == .variable and d.node == stmt) break @as(u32, @intCast(i)); // safe: declaration indexes come from the bounded frozen model.
        } else return;
        for (statements[at + 1 ..], at + 1..) |later, j| {
            if (self.refreshed(later, local)) return;
            const operation = self.moves(later, container) orelse continue;
            // A loop that runs the operation runs any use in it again after it.
            const loops = tree.fullWhile(later) != null or tree.fullFor(later) != null;
            const use = if (loops) self.firstUse(later, local) else null;
            const found = use orelse for (statements[j + 1 ..]) |after| {
                if (self.refreshed(after, local)) return;
                if (self.firstUse(after, local)) |token| break token;
            } else return;
            switch (try self.owned(container)) {
                .std => {},
                .other => return,
                .unknown => return self.c.undecided(.E002, tree.tokenStart(found), .unresolved, "a borrow of a container's storage used after an operation that may move it; the container's type does not resolve"),
            }
            const name = self.model.declarations[local].name;
            const line = self.c.project.files[self.c.file.raw()].line(tree.tokenStart(operation)) + 1;
            const message = try self.c.allocator.print("'{s}' points into storage that '{s}' on line {d} may move or free; this use reads it after", .{ name, tree.tokenSlice(operation), line });
            return self.c.at(.E002, found, message);
        }
    }

    /// The container whose storage `node` points into: `c.items` (sliced, indexed for an
    /// address, or its `ptr`), or a call on `c` that gives a pointer into it. Its path's node.
    fn borrowOf(self: Walk, node: Ast.Node.Index) ?Ast.Node.Index {
        const tree = self.tree;
        switch (tree.nodeTag(node)) {
            .grouped_expression => return self.borrowOf(tree.nodeData(node).node_and_token[0]),
            .@"try" => return self.borrowOf(tree.nodeData(node).node),
            .@"catch", .@"orelse" => return self.borrowOf(tree.nodeData(node).node_and_node[0]),
            .address_of => return self.items(tree.nodeData(node).node, true),
            .slice_open, .slice, .slice_sentinel => return self.items(tree.fullSlice(node).?.ast.sliced, false), // unreachable: a slice node is a full slice
            .field_access => {
                const data = tree.nodeData(node).node_and_token;
                if (std.mem.eql(u8, tree.tokenSlice(data[1]), "ptr")) return self.items(data[0], false);
                return self.items(node, false);
            },
            else => {},
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse return null;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
        const data = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!named(&borrowing, tree.tokenSlice(data[1]))) return null;
        return if (path(tree, data[0])) data[0] else null;
    }

    /// `c.items`, or with `address` an element or a field of one of it (`&c.items[i].f`).
    fn items(self: Walk, node: Ast.Node.Index, address: bool) ?Ast.Node.Index {
        const tree = self.tree;
        var at = node;
        if (address) while (true) switch (tree.nodeTag(at)) {
            .array_access => {
                at = tree.nodeData(at).node_and_node[0];
                break;
            },
            .field_access => at = tree.nodeData(at).node_and_token[0],
            else => return null,
        };
        if (tree.nodeTag(at) != .field_access) return null;
        const data = tree.nodeData(at).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(data[1]), "items")) return null;
        return if (path(tree, data[0])) data[0] else null;
    }

    /// The name token of a call in `stmt` on `container` that may move its storage, made
    /// where the statement falls through: outside deferred code and any branch that never does.
    fn moves(self: Walk, stmt: Ast.Node.Index, container: Ast.Node.Index) ?Ast.TokenIndex {
        const tree = self.tree;
        if (tree.nodeTag(stmt) == .@"defer" or tree.nodeTag(stmt) == .@"errdefer") return null;
        const first = tree.firstToken(stmt);
        const last = tree.lastToken(stmt);
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .field_access) continue;
            const callee: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: checked AST inventory.
            const main = tree.nodeMainToken(callee);
            if (main < first or main > last) continue;
            const data = tree.nodeData(callee).node_and_token;
            if (!named(&moving, tree.tokenSlice(data[1]))) continue;
            const parent = self.model.node_parents[i] orelse continue;
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, parent) orelse continue;
            if (call.ast.fn_expr != callee or !self.samePath(data[0], container)) continue;
            if (!self.fallsThrough(parent, stmt)) continue;
            return data[1];
        }
        return null;
    }

    /// Whether the path through `node` goes on past `stmt`: no block between them ends without
    /// falling through, and none of them is deferred or a `return`, `break` or `continue`.
    fn fallsThrough(self: Walk, node: Ast.Node.Index, stmt: Ast.Node.Index) bool {
        const tree = self.tree;
        var at = node;
        while (at != stmt) {
            const parent = self.model.node_parents[@backingInt(at)] orelse return false; // safe: the checked AST indexes its own parent table.
            switch (tree.nodeTag(parent)) {
                // Deferred, or the path ends with it (`return list.toOwnedSlice(gpa)`).
                .@"defer", .@"errdefer", .@"return", .@"break", .@"continue" => return false,
                .block, .block_semicolon, .block_two, .block_two_semicolon => {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const statements = tree.blockStatements(&buffer, parent) orelse return false;
                    if (statements.len != 0 and ends(tree, statements[statements.len - 1])) return false;
                },
                else => {},
            }
            at = parent;
        }
        return true;
    }

    /// `local = ...`: the borrow taken again, or replaced.
    fn refreshed(self: Walk, stmt: Ast.Node.Index, local: u32) bool {
        if (self.tree.nodeTag(stmt) != .assign) return false;
        const target = self.tree.nodeData(stmt).node_and_node[0];
        if (self.tree.nodeTag(target) != .identifier) return false;
        const reference = self.model.reference(target) orelse return false;
        return reference.declaration == local;
    }

    /// The first token in `node` naming `local`.
    fn firstUse(self: Walk, node: Ast.Node.Index, local: u32) ?Ast.TokenIndex {
        const first = self.tree.firstToken(node);
        const last = self.tree.lastToken(node);
        var found: ?Ast.TokenIndex = null;
        for (self.model.references) |reference| {
            if (reference.declaration != local or reference.token < first or reference.token > last) continue;
            if (found == null or reference.token < found.?) found = reference.token;
        }
        return found;
    }

    /// Whether two paths name the same storage: one declaration, then the same members.
    fn samePath(self: Walk, a: Ast.Node.Index, b: Ast.Node.Index) bool {
        const tree = self.tree;
        if (tree.nodeTag(a) != tree.nodeTag(b)) return false;
        switch (tree.nodeTag(a)) {
            .identifier => {
                const x = (self.model.reference(a) orelse return false).declaration orelse return false;
                const y = (self.model.reference(b) orelse return false).declaration orelse return false;
                return x == y;
            },
            .field_access => {
                const x = tree.nodeData(a).node_and_token;
                const y = tree.nodeData(b).node_and_token;
                return std.mem.eql(u8, tree.tokenSlice(x[1]), tree.tokenSlice(y[1])) and self.samePath(x[0], y[0]);
            },
            else => return false,
        }
    }

    const Owner = enum { std, other, unknown };
    /// Whether the container at `node` is one of std's lists or maps.
    fn owned(self: Walk, node: Ast.Node.Index) Context.Error!Owner {
        var value = try self.c.facts.resolve(self.c.file, node);
        while (value == .pointer) value = value.pointer.*;
        const container = switch (value) {
            .instance, .container => |found| found,
            .unknown => return .unknown,
            else => return .other,
        };
        if (!try self.c.facts.standard(container.file)) return .other;
        const name = self.c.project.inputs[container.file.raw()].name;
        for (containers) |file| if (std.mem.endsWith(u8, name, file)) return .std;
        return .other;
    }
};

/// A path of declarations and members: `list`, `self.list`.
fn path(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .identifier => true,
        .field_access => path(tree, tree.nodeData(node).node_and_token[0]),
        else => false,
    };
}

fn named(names: []const []const u8, name: []const u8) bool {
    for (names) |one| if (std.mem.eql(u8, one, name)) return true;
    return false;
}

/// Whether `node` never falls through: a `return`, `break`, `continue` or `unreachable`.
fn ends(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .@"return", .@"break", .@"continue", .unreachable_literal => true,
        else => false,
    };
}
