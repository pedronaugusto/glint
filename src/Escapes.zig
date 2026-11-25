//! P009 (0.8), hygiene: a pointer into a function's own frame carried out of the call, reported
//! only where the statement itself shows it. Nothing is followed through a copy, an alias or a
//! call: what a statement writes is what is read.
//!
//! A `var` declared in a function's body lives in the call's frame, which the return frees. Its
//! address (`&x`, `&x.field`, `&x[i]`), or a slice of it when it is an array (`x[a..b]`), is a
//! pointer into that frame. The cases:
//!
//! - `return` of such an address or slice (Zig refuses `return &x` itself, not a slice of a local
//!   array).
//! - a store of one, in the same statement, into a container's variable (`registered = &x`), into
//!   memory a parameter points at (`p.next = &x`, `p.* = &x`), or by `@atomicStore` there.
//!
//! A store the function undoes is none: a `defer` that runs after it and assigns the same place,
//! or one that names the local (it may unlink the address). Nothing inside `comptime` or in a
//! function returning `type` counts, where frames are comptime memory. A clean run never
//! certifies lifetimes.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Model = @import("Model.zig");
const Rule = @import("Rule.zig").Rule;
const Facts = @import("Facts.zig");
const Ast = std.zig.Ast;

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const self: Walk = .{ .c = c, .rule = rule, .tree = tree, .model = model };
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        // What leaves the statement, and the place it is stored into (none for a return).
        const operand: Ast.Node.Index, const place: ?Ast.Node.Index = switch (tag) {
            .@"return" => .{ tree.nodeData(node).opt_node.unwrap() orelse continue, null },
            .assign => .{ tree.nodeData(node).node_and_node[1], tree.nodeData(node).node_and_node[0] },
            .builtin_call, .builtin_call_comma => blk: {
                if (!Facts.isBuiltin(tree, node, "@atomicStore")) continue;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, node, &buffer);
                if (args.len < 3) continue;
                const pointer = Facts.ungrouped(tree, args[1]);
                if (tree.nodeTag(pointer) != .address_of) continue;
                break :blk .{ args[2], tree.nodeData(pointer).node };
            },
            else => continue,
        };
        if (c.inTest(tree.nodeMainToken(node))) continue;
        const function = self.enclosing(node) orelse continue;
        const local = (try self.frameAddress(operand, function)) orelse continue;
        if (place) |target| {
            if (!self.outlives(target)) continue;
            if (try self.restored(function, target, node) or self.unlinked(function, node, local)) continue;
        }
        const name = model.declarations[@backingInt(local)].name;
        const message = if (place == null)
            try c.allocator.print("returns a pointer into local '{s}', which the return frees", .{name})
        else
            try c.allocator.print("stores a pointer into local '{s}' where it outlives the call that frees it", .{name});
        try c.at(rule, tree.nodeMainToken(operand), message);
    }
}

const Walk = struct {
    c: *Context,
    rule: Rule,
    tree: *const Ast,
    model: *const Model,

    /// The function whose body holds `node`, or null outside one, inside `comptime`, or in a
    /// function returning `type`: all comptime frames.
    fn enclosing(self: Walk, node: Ast.Node.Index) ?Ast.Node.Index {
        var at = node;
        while (self.model.parentOf(at)) |parent| : (at = parent) {
            switch (self.tree.nodeTag(parent)) {
                .@"comptime" => return null,
                .fn_decl => {
                    var buffer: [1]Ast.Node.Index = undefined;
                    const proto = self.tree.fullFnProto(&buffer, self.tree.nodeData(parent).node_and_node[0]) orelse return null;
                    const result = proto.ast.return_type.unwrap() orelse return null;
                    if (self.tree.nodeTag(result) == .identifier and std.mem.eql(u8, self.tree.tokenSlice(self.tree.nodeMainToken(result)), "type")) return null;
                    return parent;
                },
                else => {},
            }
        }
        return null;
    }

    /// The `var` of `function`'s own (not `comptime`) that the written value is a pointer into:
    /// `&x`, `&x.f`, `&x[i]` of a value `x` that is no pointer, or a slice of an array `x`.
    fn frameAddress(self: Walk, written: Ast.Node.Index, function: Ast.Node.Index) Context.Error!?Model.Declaration.Id {
        const tree = self.tree;
        const node = Facts.ungrouped(tree, written);
        switch (tree.nodeTag(node)) {
            .address_of => {
                var at = Facts.ungrouped(tree, tree.nodeData(node).node);
                var steps: usize = 0;
                while (true) : (steps += 1) switch (tree.nodeTag(at)) {
                    .field_access => at = Facts.ungrouped(tree, tree.nodeData(at).node_and_token[0]),
                    .array_access => at = Facts.ungrouped(tree, tree.nodeData(at).node_and_node[0]),
                    else => break,
                };
                const d = self.variable(at, function) orelse return null;
                // A path through a pointer the local holds reaches the pointed memory.
                if (steps != 0 and !try self.held(at, false)) return null;
                return d;
            },
            .slice_open, .slice, .slice_sentinel => {
                const sliced = Facts.ungrouped(tree, (tree.fullSlice(node) orelse return null).ast.sliced);
                const d = self.variable(sliced, function) orelse return null;
                return if (try self.held(sliced, true)) d else null;
            },
            else => return null,
        }
    }

    /// The `var` an identifier names, declared in `function`'s body, not `comptime`.
    fn variable(self: Walk, identifier: Ast.Node.Index, function: Ast.Node.Index) ?Model.Declaration.Id {
        if (self.tree.nodeTag(identifier) != .identifier) return null;
        const reference = self.model.reference(identifier) orelse return null;
        const d = reference.declaration orelse return null;
        const record = self.model.declarations[@backingInt(d)];
        if (record.kind != .variable or self.enclosing(record.node) != function) return null;
        const decl = self.tree.fullVarDecl(record.node) orelse return null;
        if (decl.comptime_token != null or self.tree.tokenTag(decl.ast.mut_token) != .keyword_var) return null;
        return d;
    }

    /// Whether the local's value is held in its own memory: its type is known and no pointer
    /// (`array`, an array). A local in code no compiled root holds is no pass: its site is
    /// counted not reached (`Context.unknownAt`).
    fn held(self: Walk, identifier: Ast.Node.Index, array: bool) Context.Error!bool {
        const value = try self.c.resolveIn(self.c.file, identifier);
        return switch (value) {
            .array => true,
            .instance, .scalar, .literal, .optional, .error_union => !array,
            .unknown => |why| {
                if (why == .not_reached) try self.c.unknownAt(self.rule, self.tree.nodeMainToken(identifier), why);
                return false;
            },
            else => false,
        };
    }

    /// Whether an assignment's target outlives the call: a container's variable, or a place
    /// through a parameter (a pointer the caller holds; a parameter by value is not assignable).
    fn outlives(self: Walk, target: Ast.Node.Index) bool {
        var at = Facts.ungrouped(self.tree, target);
        var steps: usize = 0;
        while (true) : (steps += 1) switch (self.tree.nodeTag(at)) {
            .field_access, .unwrap_optional => at = Facts.ungrouped(self.tree, self.tree.nodeData(at).node_and_token[0]),
            .array_access => at = Facts.ungrouped(self.tree, self.tree.nodeData(at).node_and_node[0]),
            .deref => at = Facts.ungrouped(self.tree, self.tree.nodeData(at).node),
            else => break,
        };
        if (self.tree.nodeTag(at) != .identifier) return false;
        const reference = self.model.reference(at) orelse return false;
        const d = reference.declaration orelse return false;
        const decl = self.model.declarations[@backingInt(d)];
        return switch (decl.kind) {
            .parameter => steps != 0,
            .variable => switch (self.model.scopes[@backingInt(decl.scope)].kind) {
                .file, .container => true,
                else => false,
            },
            else => false,
        };
    }

    /// Whether a `defer` of `function` that runs after the store assigns the target again, as
    /// one of its own statements (never under a branch): a registration cleared on every exit.
    fn restored(self: Walk, function: Ast.Node.Index, target: Ast.Node.Index, store: Ast.Node.Index) Context.Error!bool {
        const tree = self.tree;
        const later = self.deferring(store);
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .@"defer") continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (self.enclosing(node) != function) continue;
            if (later) |made| if (!self.runsAfter(node, made)) continue;
            const deferred = tree.nodeData(node).node;
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, deferred) orelse &.{deferred};
            for (statements) |statement| {
                if (tree.nodeTag(statement) != .assign) continue;
                const written = tree.nodeData(statement).node_and_node[0];
                if (try self.c.samePlace(self.c.file, written, target) == .yes) return true;
            }
        }
        return false;
    }

    /// Whether a `defer` of `function` that runs after the store names the local: one that may
    /// unlink its address before the frame goes (`while (link.* != &waiter) ...; link.* =
    /// waiter.next;`, aegis Condition's waiter). Hygiene reports only what is certain.
    fn unlinked(self: Walk, function: Ast.Node.Index, store: Ast.Node.Index, local: Model.Declaration.Id) bool {
        const tree = self.tree;
        const later = self.deferring(store);
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .@"defer") continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (self.enclosing(node) != function) continue;
            if (later) |made| if (!self.runsAfter(node, made)) continue;
            const deferred = tree.nodeData(node).node;
            const opens = tree.firstToken(deferred);
            const closes = tree.lastToken(deferred);
            for (tree.nodes.items(.tag), 0..) |named, k| {
                if (named != .identifier) continue;
                const identifier: Ast.Node.Index = @fromBackingInt(@intCast(k));
                const at = tree.nodeMainToken(identifier);
                if (at < opens or at > closes) continue;
                const reference = self.model.reference(identifier) orelse continue;
                if (reference.declaration == local) return true;
            }
        }
        return false;
    }

    /// The `defer` or `errdefer` that runs `node`, if one of its function does.
    fn deferring(self: Walk, node: Ast.Node.Index) ?Ast.Node.Index {
        var at = node;
        while (self.model.parentOf(at)) |parent| : (at = parent) switch (self.tree.nodeTag(parent)) {
            .@"defer", .@"errdefer" => return parent,
            .fn_decl => return null,
            else => {},
        };
        return null;
    }

    /// Whether the `defer` `node` runs after the defer `other` as their scopes exit: it is
    /// declared before it in a block that holds it.
    fn runsAfter(self: Walk, node: Ast.Node.Index, other: Ast.Node.Index) bool {
        if (node == other or self.tree.nodeMainToken(node) >= self.tree.nodeMainToken(other)) return false;
        const block = self.model.parentOf(node) orelse return false;
        var at = other;
        while (self.model.parentOf(at)) |parent| : (at = parent) if (parent == block) return true;
        return false;
    }
};
