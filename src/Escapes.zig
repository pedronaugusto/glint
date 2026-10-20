//! E001: a pointer into a function's own frame that outlives the call.
//!
//! A `var` declared in a function's body lives in the call's frame, which the return frees.
//! Its address (`&x`, `&x.field`, `&x[i]`), or a slice of it when it is an array (`x[a..b]`),
//! is a pointer into that frame. Zig refuses `return &x` itself ("returning address of expired
//! local variable"); it does not refuse a slice of a local array, a pointer carried out in a
//! returned struct literal or through a local alias (`const out = &x; return out;`), or one
//! stored through a parameter or into a container's variable. Those are this rule's.
//!
//! A heuristic (designs/glint.md §6), reported. Only `var` locals count: a comptime-known
//! `const` is static memory. A path through a field or an element counts only where the local's
//! written type resolves to a value (a container or an array), never through a pointer, which
//! Zig dereferences on access. Nothing inside `comptime` or in a function returning `type`
//! counts, where frames are comptime memory. A store the function undoes does not
//! outlive the call: a `defer` of it names the local (an intrusive waiter unlinked) or assigns
//! the target again (a registration cleared). An alias is followed one step,
//! within the function. A clean run never certifies lifetimes.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Model = @import("Model.zig");
const Ast = std.zig.Ast;

pub fn check(c: *Context) Context.Error!void {
    if (!c.config.has(.E001)) return;
    const index = c.file.raw();
    const tree = &c.project.files[index].tree;
    const model = &c.project.models[index];
    const self: Walk = .{ .c = c, .tree = tree, .model = model };
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: checked AST inventory.
        const operand: Ast.Node.Index, const stored: ?Ast.Node.Index = switch (tag) {
            .@"return" => .{ tree.nodeData(node).opt_node.unwrap() orelse continue, null },
            .assign => .{ tree.nodeData(node).node_and_node[1], tree.nodeData(node).node_and_node[0] },
            else => continue,
        };
        const function = self.enclosing(node) orelse continue;
        if (stored) |target| if (!self.outlives(target)) continue;
        const local = (try self.escaping(operand, function, true)) orelse continue;
        if (stored) |target| if (self.undone(function, local) or self.restored(function, target)) continue;
        const name = model.declarations[local].name;
        const message = if (stored == null)
            try c.allocator.print("returns a pointer into local '{s}', which the return frees", .{name})
        else
            try c.allocator.print("stores a pointer into local '{s}' where it outlives the call that frees it", .{name});
        try c.at(.E001, tree.nodeMainToken(operand), message);
    }
}

const Walk = struct {
    c: *Context,
    tree: *const Ast,
    model: *const Model,

    /// The function whose body holds `node`, or null outside one, inside `comptime`, or in a
    /// function returning `type`: all comptime frames.
    fn enclosing(self: Walk, node: Ast.Node.Index) ?Ast.Node.Index {
        var at = node;
        while (self.model.node_parents[@backingInt(at)]) |parent| : (at = parent) { // safe: the checked AST indexes its own parent table.
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

    /// The declaration an identifier names, when it is one of `function`'s own: declared in its
    /// body, outside any nested function or `comptime`.
    fn own(self: Walk, identifier: Ast.Node.Index, function: Ast.Node.Index) ?u32 {
        const reference = self.model.reference(identifier) orelse return null;
        const d = reference.declaration orelse return null;
        const decl = self.model.declarations[d];
        if (decl.kind != .variable) return null;
        if (self.enclosing(decl.node) != function) return null;
        return d;
    }

    /// The `var` local a pointer value reaches into, or null. `direct` follows one alias.
    fn escaping(self: Walk, node: Ast.Node.Index, function: Ast.Node.Index, direct: bool) Context.Error!?u32 {
        const tree = self.tree;
        switch (tree.nodeTag(node)) {
            .grouped_expression => return self.escaping(tree.nodeData(node).node_and_token[0], function, direct),
            .address_of => {
                const inner = tree.nodeData(node).node;
                if (tree.nodeTag(inner) == .identifier) return self.variable(inner, function);
                const root = self.storage(inner) orelse return null;
                const d = self.variable(root, function) orelse return null;
                return if (try self.value(d)) d else null;
            },
            .slice_open, .slice, .slice_sentinel => {
                const sliced = (tree.fullSlice(node) orelse return null).ast.sliced;
                if (tree.nodeTag(sliced) != .identifier) return null;
                const d = self.variable(sliced, function) orelse return null;
                return if (try self.array(d)) d else null;
            },
            .identifier => {
                if (!direct) return null;
                const d = self.own(node, function) orelse return null;
                const decl = self.tree.fullVarDecl(self.model.declarations[d].node) orelse return null;
                if (tree.tokenTag(decl.ast.mut_token) != .keyword_const) return null;
                const init = decl.ast.init_node.unwrap() orelse return null;
                return self.escaping(init, function, false);
            },
            else => {
                var buffer: [2]Ast.Node.Index = undefined;
                const literal = tree.fullStructInit(&buffer, node) orelse return null;
                for (literal.ast.fields) |field| if (try self.escaping(field, function, direct)) |d| return d;
                return null;
            },
        }
    }

    /// A `var` of `function`'s own, not comptime.
    fn variable(self: Walk, identifier: Ast.Node.Index, function: Ast.Node.Index) ?u32 {
        const d = self.own(identifier, function) orelse return null;
        const decl = self.tree.fullVarDecl(self.model.declarations[d].node) orelse return null;
        if (self.tree.tokenTag(decl.ast.mut_token) != .keyword_var or decl.comptime_token != null) return null;
        return d;
    }

    /// The identifier at the root of a path of fields and elements, never through `.*`.
    fn storage(self: Walk, node: Ast.Node.Index) ?Ast.Node.Index {
        var at = node;
        while (true) switch (self.tree.nodeTag(at)) {
            .identifier => return at,
            .field_access => at = self.tree.nodeData(at).node_and_token[0],
            .array_access => at = self.tree.nodeData(at).node_and_node[0],
            .grouped_expression => at = self.tree.nodeData(at).node_and_token[0],
            else => return null,
        };
    }

    /// Whether a local's written type is a value its fields and elements live in: a container
    /// or an array, never a pointer Zig would dereference.
    fn value(self: Walk, d: u32) Context.Error!bool {
        const kind = self.declaredType(d) orelse return false;
        return switch (try self.c.facts.resolve(self.c.file, kind)) {
            .container, .array => true,
            else => false,
        };
    }

    fn array(self: Walk, d: u32) Context.Error!bool {
        const kind = self.declaredType(d) orelse return false;
        return switch (self.tree.nodeTag(kind)) {
            .array_type, .array_type_sentinel => true,
            else => (try self.c.facts.resolve(self.c.file, kind)) == .array,
        };
    }

    fn declaredType(self: Walk, d: u32) ?Ast.Node.Index {
        const decl = self.tree.fullVarDecl(self.model.declarations[d].node) orelse return null;
        return decl.ast.type_node.unwrap();
    }

    /// Whether an assignment's target outlives the call: reached through a parameter (a pointer
    /// the caller holds) or a container's variable.
    fn outlives(self: Walk, target: Ast.Node.Index) bool {
        if (self.tree.nodeTag(target) == .identifier) return self.global(target);
        var at = target;
        while (true) switch (self.tree.nodeTag(at)) {
            .identifier => break,
            .field_access => at = self.tree.nodeData(at).node_and_token[0],
            .array_access => at = self.tree.nodeData(at).node_and_node[0],
            .deref => at = self.tree.nodeData(at).node,
            .grouped_expression => at = self.tree.nodeData(at).node_and_token[0],
            else => return false,
        };
        const reference = self.model.reference(at) orelse return false;
        const d = reference.declaration orelse return false;
        return self.model.declarations[d].kind == .parameter or self.global(at);
    }

    fn global(self: Walk, identifier: Ast.Node.Index) bool {
        const reference = self.model.reference(identifier) orelse return false;
        const d = reference.declaration orelse return false;
        const decl = self.model.declarations[d];
        if (decl.kind != .variable) return false;
        return switch (self.model.scopes[decl.scope].kind) {
            .file, .container => true,
            else => false,
        };
    }

    /// Whether a `defer` of `function` names the local: the function deregisters what it
    /// stored (an intrusive waiter unlinked, a registration cleared) before the frame goes.
    fn undone(self: Walk, function: Ast.Node.Index, local: u32) bool {
        const tree = self.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .@"defer") continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: checked AST inventory.
            if (self.enclosing(node) != function) continue;
            for (self.model.references) |reference| {
                if (reference.declaration != local) continue;
                if (reference.token >= tree.firstToken(node) and reference.token <= tree.lastToken(node)) return true;
            }
        }
        return false;
    }

    /// Whether a `defer` of `function` assigns the target again, written the same way: a
    /// scoped registration cleared before the frame goes.
    fn restored(self: Walk, function: Ast.Node.Index, target: Ast.Node.Index) bool {
        const tree = self.tree;
        const from = tree.firstToken(target);
        const count = tree.lastToken(target) + 1 - from;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .@"defer") continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: checked AST inventory.
            if (self.enclosing(node) != function) continue;
            var t = tree.firstToken(node) + count;
            while (t <= tree.lastToken(node)) : (t += 1) {
                if (tree.tokenTag(t) != .equal) continue;
                for (0..count) |k| {
                    const offset: u32 = @intCast(k); // safe: a node's token count fits u32.
                    if (!std.mem.eql(u8, tree.tokenSlice(t - count + offset), tree.tokenSlice(from + offset))) break;
                } else return true;
            }
        }
        return false;
    }
};
