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
        if (stored) |target| if (!try self.outlives(target)) continue;
        const reached = try self.escaping(operand, function, 0);
        if (reached == .none) continue;
        if (stored) |target| if (try self.restored(function, target)) continue;
        const local = switch (reached) {
            .none => unreachable, // unreachable: left above
            .unknown => |why| {
                try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(operand)), why.reason, why.detail);
                continue;
            },
            .local => |d| d,
        };
        const name = model.declarations[@backingInt(local)].name;
        const message = if (stored == null)
            try c.allocator.print("returns a pointer into local '{s}', which the return frees", .{name})
        else
            try c.allocator.print("stores a pointer into local '{s}' where it outlives the call that frees it", .{name});
        try c.at(rule, tree.nodeMainToken(operand), message);
    }
}

/// What a pointer value reaches into: a local of the function's frame, none, or what may be one
/// and why it is not known.
const Reached = union(enum) {
    local: Model.Declaration.Id,
    none,
    unknown: struct { reason: @import("Report.zig").Coverage.Reason, detail: []const u8 },
};

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

    /// The local a pointer value reaches into: through `depth` aliases so far.
    fn escaping(self: Walk, written: Ast.Node.Index, function: Ast.Node.Index, depth: u8) Context.Error!Reached {
        const tree = self.tree;
        const node = Facts.ungrouped(tree, written);
        if (depth > 8) return .{ .unknown = .{ .reason = .budget_exhausted, .detail = "a pointer followed through more aliases than are read may point into a local the return frees" } };
        switch (tree.nodeTag(node)) {
            .address_of => {
                const inner = tree.nodeData(node).node;
                const root = (try self.storage(inner)) orelse return .none;
                // The local itself is its frame's memory, whatever its type.
                if (root == Facts.ungrouped(tree, inner)) return reach(self.variable(root, function));
                const d = self.variable(root, function) orelse return .none;
                return if (try self.value(d)) .{ .local = d } else .none;
            },
            .slice_open, .slice, .slice_sentinel => {
                const sliced = (tree.fullSlice(node) orelse return .none).ast.sliced;
                const root = (try self.storage(sliced)) orelse return .none;
                if (root != Facts.ungrouped(tree, sliced)) return .none;
                const d = self.variable(root, function) orelse return .none;
                if (try self.array(d)) return .{ .local = d };
                // A pointer's slice points where the pointer does: what the local is given, but
                // a slice of itself (`s = s[1..]`), which holds no memory it did not.
                if (try self.c.facts.holdsNoAddress(try self.typeOf(d))) return .none;
                const given = (try self.c.facts.givenTo(.{ .file = self.c.file, .index = d }, true)) orelse
                    return .{ .unknown = .{ .reason = .unresolved, .detail = "a pointer named by a local given a value no store here shows (its address taken, its bytes written) may point into a local the return frees" } };
                var others: std.ArrayList(Facts.Key) = .empty;
                for (given) |each| if (!try self.slicesItself(each.node, d)) try others.append(self.c.allocator, each);
                return self.first(others.items, function, depth + 1);
            },
            // A name for a pointer: each value it or a part of it is given (`Facts.givenTo`),
            // what a `const` holds; a store that may give it any value may give it a local's
            // address.
            .identifier => {
                const d = self.own(node, function) orelse return .none;
                // A value that holds no pointer (`[4]u8` returned whole) points nowhere.
                if (try self.c.facts.holdsNoAddress(try self.typeOf(d))) return .none;
                const given = (try self.c.facts.givenTo(.{ .file = self.c.file, .index = d }, true)) orelse
                    return .{ .unknown = .{ .reason = .unresolved, .detail = "a pointer named by a local given a value no store here shows (its address taken, its bytes written) may point into a local the return frees" } };
                return self.first(given, function, depth + 1);
            },
            else => {
                var buffer: [2]Ast.Node.Index = undefined;
                const literal = tree.fullStructInit(&buffer, node) orelse return .none;
                var fields: std.ArrayList(Facts.Key) = .empty;
                for (literal.ast.fields) |field| try fields.append(self.c.allocator, .{ .file = self.c.file, .node = field });
                return self.first(fields.items, function, depth);
            },
        }
    }

    /// Whether `given` is a slice of the local `d` itself, by its own name.
    fn slicesItself(self: Walk, given: Ast.Node.Index, d: Model.Declaration.Id) Context.Error!bool {
        const node = Facts.ungrouped(self.tree, given);
        const sliced = (self.tree.fullSlice(node) orelse return false).ast.sliced;
        const root = (try self.storage(sliced)) orelse return false;
        if (root != Facts.ungrouped(self.tree, sliced)) return false;
        const reference = self.model.reference(root) orelse return false;
        return reference.declaration == d;
    }

    /// The first local one of `values` reaches into; else what may be one, or none.
    fn first(self: Walk, values: []const Facts.Key, function: Ast.Node.Index, depth: u8) Context.Error!Reached {
        var out: Reached = .none;
        for (values) |each| switch (try self.escaping(each.node, function, depth)) {
            .local => |d| return .{ .local = d },
            .unknown => |why| out = .{ .unknown = why },
            .none => {},
        };
        return out;
    }

    fn reach(local: ?Model.Declaration.Id) Reached {
        return if (local) |d| .{ .local = d } else .none;
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

    /// The name at the root of a path of fields and elements that stay in its memory: no step
    /// crosses a pointer (`Facts.accesses.pathOf`).
    fn storage(self: Walk, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
        const path = try Facts.accesses.pathOf(self.c.facts, self.c.file, node);
        for (path.steps[0 .. path.steps.len - 1]) |step| switch (step.kind) {
            .field, .index => if (step.crosses) return null,
            .slice, .unwrap, .deref, .root => return null,
        };
        if (path.root != .decl) return null;
        return path.steps[path.steps.len - 1].node;
    }

    /// Whether a local's fields and elements live in it: its type, written or of its value, is
    /// no pointer Zig would dereference. A type the reading does not know may be a value.
    fn value(self: Walk, d: Model.Declaration.Id) Context.Error!bool {
        // A value where any build's type is one, or one not known.
        const typed = try self.typeOf(d);
        var each: Facts.Join = .{};
        for (Facts.valueParts(&typed)) |part| each.add(part, switch (part) {
            .pointer => false,
            .alternatives => null, // a choice, never a part (valueParts): not known
            else => true,
        });
        return each.any() orelse true;
    }

    /// Whether a local is an array a slice of which is its frame's memory: its type, written
    /// or of its value, is an array, or one the reading does not know but for a local its value
    /// makes a pointer (`Facts.makesPointer`).
    fn array(self: Walk, d: Model.Declaration.Id) Context.Error!bool {
        // Made a pointer (`@ptrFromInt`, a pointer cast), it is one whatever its type spells.
        const unknown = if (self.tree.fullVarDecl(self.model.declarations[@backingInt(d)].node)) |decl|
            !(if (decl.ast.init_node.unwrap()) |init| self.c.facts.makesPointer(self.c.file, init) else false)
        else
            true;
        // An array where any build's type is one.
        const typed = try self.typeOf(d);
        for (Facts.valueParts(&typed)) |part| switch (part) {
            .array => return true,
            // A choice, which valueParts never gives as a part, is read as one not known.
            .unknown, .alternatives => if (unknown) return true,
            else => {},
        };
        return false;
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
    fn outlives(self: Walk, target: Ast.Node.Index) Context.Error!bool {
        const path = try Facts.accesses.pathOf(self.c.facts, self.c.file, target);
        if (path.root != .decl) return false;
        const root = path.steps[path.steps.len - 1].node;
        // The name itself is its frame's, a parameter's included; a place through it may be
        // the caller's.
        if (path.steps.len == 1) return self.global(root);
        const reference = self.model.reference(root) orelse return false;
        const d = reference.declaration orelse return false;
        return self.model.declarations[@backingInt(d)].kind == .parameter or self.global(root);
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
            for (statements) |statement| for (try Facts.accesses.storesIn(self.c.facts, self.c.file)) |site| {
                if (site.node != statement or site.kind != .set) continue;
                const written = site.target orelse continue;
                if (try Facts.accesses.samePlace(self.c.facts, self.c.file, written, target) == .yes) return true;
            };
        }
        return false;
    }
};

/// Whether a value is a literal the program compiles in: numbers, characters, strings, enum
/// literals, and array and struct literals and concatenations of them.
fn compiledIn(tree: *const Ast, written: Ast.Node.Index) bool {
    const node = Facts.ungrouped(tree, written);
    switch (tree.nodeTag(node)) {
        .number_literal, .char_literal, .string_literal, .multiline_string_literal, .enum_literal => return true,
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
