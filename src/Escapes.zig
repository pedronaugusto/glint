//! E001: a pointer into a function's own frame that outlives the call.
//!
//! A `var` declared in a function's body lives in the call's frame, which the return frees.
//! Its address (`&x`, `&x.field`, `&x[i]`), or a slice of it when it is an array (`x[a..b]`),
//! is a pointer into that frame. Zig refuses `return &x` itself ("returning address of expired
//! local variable"); it does not refuse a slice of a local array, a pointer carried out in a
//! returned struct literal or through a local alias (`const out = &x; return out;`), or one
//! stored through a parameter or into a container's variable. Those are this rule's.
//!
//! A heuristic (designs/glint.md §6), reported. A `var` local counts, and a `const` one but where
//! its value is a literal the program compiles in (static memory). A path through a field or an
//! element counts but where the local's type, written or of its value, is a pointer, which Zig
//! dereferences on access. Nothing inside `comptime` or in a function returning `type` counts,
//! where frames are comptime memory. A store the function undoes does not outlive the call: a
//! `defer` that assigns the target again (a registration cleared) on every exit. Aliases are
//! followed within the function, through a `const`'s value and every value a `var` is given. A
//! clean run never certifies lifetimes.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Model = @import("Model.zig");
const Rule = @import("Rule.zig").Rule;
const Facts = @import("Facts.zig");
const Ast = std.zig.Ast;

/// A value that may leave the call: a `return`'s, or a store's into `stored`.
const Found = struct { node: Ast.Node.Index, operand: Ast.Node.Index, stored: ?Ast.Node.Index };

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const self: Walk = .{ .c = c, .tree = tree, .model = model };
    var found: std.ArrayList(Found) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        try found.append(c.allocator, .{ .node = node, .operand = tree.nodeData(node).opt_node.unwrap() orelse continue, .stored = null });
    }
    for (try Facts.accesses.storesIn(c.facts, c.file)) |site| {
        if (site.kind != .set) continue;
        try found.append(c.allocator, .{ .node = site.node, .operand = site.value orelse continue, .stored = site.target });
    }
    for (found.items) |each| {
        const node = each.node;
        const operand = each.operand;
        const stored = each.stored;
        if (c.inTest(tree.nodeMainToken(node))) continue;
        const function = self.enclosing(node) orelse continue;
        if (stored) |target| if (!self.outlives(target)) continue;
        const local = (try self.escaping(operand, function, 0)) orelse continue;
        if (stored) |target| if (try self.restored(function, target)) continue;
        const name = model.declarations[@backingInt(local)].name;
        const message = if (stored == null)
            try c.allocator.print("returns a pointer into local '{s}', which the return frees", .{name})
        else
            try c.allocator.print("stores a pointer into local '{s}' where it outlives the call that frees it", .{name});
        try c.at(rule, tree.nodeMainToken(operand), message);
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

    /// The declaration an identifier names, when it is one of `function`'s own: declared in its
    /// body, outside any nested function or `comptime`.
    fn own(self: Walk, identifier: Ast.Node.Index, function: Ast.Node.Index) ?Model.Declaration.Id {
        const reference = self.model.reference(identifier) orelse return null;
        const d = reference.declaration orelse return null;
        const decl = self.model.declarations[@backingInt(d)];
        if (decl.kind != .variable) return null;
        if (self.enclosing(decl.node) != function) return null;
        return d;
    }

    /// The local a pointer value reaches into, or null: through `depth` aliases so far.
    fn escaping(self: Walk, node: Ast.Node.Index, function: Ast.Node.Index, depth: u8) Context.Error!?Model.Declaration.Id {
        const tree = self.tree;
        if (depth > 8) return null;
        switch (tree.nodeTag(node)) {
            .grouped_expression => return self.escaping(tree.nodeData(node).node_and_token[0], function, depth),
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
            // A name for a pointer: what its `const` holds, or each value its `var` is given.
            .identifier => {
                const d = self.own(node, function) orelse return null;
                const decl = self.tree.fullVarDecl(self.model.declarations[@backingInt(d)].node) orelse return null;
                if (decl.ast.init_node.unwrap()) |init| if (try self.escaping(init, function, depth + 1)) |reached| return reached;
                if (tree.tokenTag(decl.ast.mut_token) == .keyword_const) return null;
                for (try Facts.accesses.writes(self.c.facts, .{ .declaration = .{ .file = self.c.file, .index = d } }, &.{self.c.file})) |site| {
                    if (site.kind != .set and site.kind != .init or site.part) continue;
                    if (try self.escaping(site.value orelse continue, function, depth + 1)) |reached| return reached;
                }
                return null;
            },
            else => {
                var buffer: [2]Ast.Node.Index = undefined;
                const literal = tree.fullStructInit(&buffer, node) orelse return null;
                for (literal.ast.fields) |field| if (try self.escaping(field, function, depth)) |d| return d;
                return null;
            },
        }
    }

    /// A local of `function`'s own in its frame: a `var` not comptime, or a `const` whose value
    /// is no literal the program compiles in.
    fn variable(self: Walk, identifier: Ast.Node.Index, function: Ast.Node.Index) ?Model.Declaration.Id {
        const d = self.own(identifier, function) orelse return null;
        const decl = self.tree.fullVarDecl(self.model.declarations[@backingInt(d)].node) orelse return null;
        if (decl.comptime_token != null) return null;
        if (self.tree.tokenTag(decl.ast.mut_token) == .keyword_const) {
            const init = decl.ast.init_node.unwrap() orelse return null;
            if (compiledIn(self.tree, init)) return null;
        }
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

    /// Whether a local's fields and elements live in it: its type, written or of its value, is
    /// no pointer Zig would dereference. A type the reading does not know may be a value.
    fn value(self: Walk, d: Model.Declaration.Id) Context.Error!bool {
        return switch (try self.typeOf(d)) {
            .pointer => false,
            else => true,
        };
    }

    /// Whether a local is an array a slice of which is its frame's memory: its type, written
    /// or of its value, is an array, or one the reading does not know.
    fn array(self: Walk, d: Model.Declaration.Id) Context.Error!bool {
        const decl = self.tree.fullVarDecl(self.model.declarations[@backingInt(d)].node) orelse return false;
        if (decl.ast.type_node.unwrap()) |kind| switch (self.tree.nodeTag(kind)) {
            .array_type, .array_type_sentinel => return true,
            else => {},
        };
        return switch (try self.typeOf(d)) {
            .array, .unknown => true,
            else => false,
        };
    }

    /// What a local's type resolves to: the type it is written with, or its value's.
    fn typeOf(self: Walk, d: Model.Declaration.Id) Context.Error!@import("Facts.zig").Value {
        const decl = self.tree.fullVarDecl(self.model.declarations[@backingInt(d)].node) orelse return .{ .unknown = .unsupported };
        if (decl.ast.type_node.unwrap()) |kind| return self.c.facts.resolve(self.c.file, kind);
        const init = decl.ast.init_node.unwrap() orelse return .{ .unknown = .unsupported };
        return self.c.facts.resolve(self.c.file, init);
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
        return self.model.declarations[@backingInt(d)].kind == .parameter or self.global(at);
    }

    fn global(self: Walk, identifier: Ast.Node.Index) bool {
        const reference = self.model.reference(identifier) orelse return false;
        const d = reference.declaration orelse return false;
        const decl = self.model.declarations[@backingInt(d)];
        if (decl.kind != .variable) return false;
        return switch (self.model.scopes[@backingInt(decl.scope)].kind) {
            .file, .container => true,
            else => false,
        };
    }

    /// Whether two targets name the same memory by meaning: names of one declaration, the same
    /// member (by its declaration where the holder's type resolves) of the same holder, the same
    /// pointee, an element at a literal index spelled the same.
    fn same(self: Walk, a: Ast.Node.Index, b: Ast.Node.Index, depth: u8) Context.Error!bool {
        const tree = self.tree;
        if (depth > 16) return false;
        if (tree.nodeTag(a) == .grouped_expression) return self.same(tree.nodeData(a).node_and_token[0], b, depth + 1);
        if (tree.nodeTag(b) == .grouped_expression) return self.same(a, tree.nodeData(b).node_and_token[0], depth + 1);
        if (tree.nodeTag(a) != tree.nodeTag(b)) return false;
        switch (tree.nodeTag(a)) {
            .identifier => {
                const left = (self.model.reference(a) orelse return false).declaration orelse return false;
                const right = (self.model.reference(b) orelse return false).declaration orelse return false;
                return left == right;
            },
            .field_access => {
                const left = try self.c.facts.definition(self.c.file, a);
                const right = try self.c.facts.definition(self.c.file, b);
                if (left != null or right != null) {
                    if (!std.meta.eql(left, right)) return false;
                } else if (!std.mem.eql(u8, try Model.identifier(self.c.allocator, tree.tokenSlice(tree.nodeData(a).node_and_token[1])), try Model.identifier(self.c.allocator, tree.tokenSlice(tree.nodeData(b).node_and_token[1])))) return false;
                return self.same(tree.nodeData(a).node_and_token[0], tree.nodeData(b).node_and_token[0], depth + 1);
            },
            .deref => return self.same(tree.nodeData(a).node, tree.nodeData(b).node, depth + 1),
            .array_access => {
                const left_holder, const left_index = tree.nodeData(a).node_and_node;
                const right_holder, const right_index = tree.nodeData(b).node_and_node;
                if (tree.nodeTag(left_index) != .number_literal or tree.nodeTag(right_index) != .number_literal) return false;
                if (!std.mem.eql(u8, tree.getNodeSource(left_index), tree.getNodeSource(right_index))) return false;
                return self.same(left_holder, right_holder, depth + 1);
            },
            else => return false,
        }
    }

    /// Whether a `defer` of `function` assigns the target again, naming the same memory, as its
    /// statement or one of its block's own statements (never under a branch): a scoped
    /// registration cleared on every exit before the frame goes.
    fn restored(self: Walk, function: Ast.Node.Index, target: Ast.Node.Index) Context.Error!bool {
        const tree = self.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .@"defer") continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (self.enclosing(node) != function) continue;
            const deferred = tree.nodeData(node).node;
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, deferred) orelse &.{deferred};
            for (statements) |statement| {
                if (tree.nodeTag(statement) != .assign) continue;
                if (try self.same(tree.nodeData(statement).node_and_node[0], target, 0)) return true;
            }
        }
        return false;
    }
};

/// Whether a value is a literal the program compiles in: numbers, characters, strings, enum
/// literals, and array and struct literals and concatenations of them.
fn compiledIn(tree: *const Ast, node: Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .number_literal, .char_literal, .string_literal, .multiline_string_literal, .enum_literal => return true,
        .grouped_expression => return compiledIn(tree, tree.nodeData(node).node_and_token[0]),
        .array_cat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return compiledIn(tree, lhs) and compiledIn(tree, rhs);
        },
        else => {},
    }
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullArrayInit(&buffer, node)) |literal| {
        for (literal.ast.elements) |element| if (!compiledIn(tree, element)) return false;
        return true;
    }
    if (tree.fullStructInit(&buffer, node)) |literal| {
        for (literal.ast.fields) |field| if (!compiledIn(tree, field)) return false;
        return true;
    }
    return false;
}
