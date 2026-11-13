//! P009 (0.8): a pointer into a function's own frame that a `return` carries out, reported only
//! where certain. Stores of one (through a parameter, into a container's variable) are no longer
//! read: `scope` and `handle` carry those.
//!
//! A `var` declared in a function's body lives in the call's frame, which the return frees.
//! Its address (`&x`, `&x.field`, `&x[i]`), or a slice of it when it is an array (`x[a..b]`),
//! is a pointer into that frame. Zig refuses `return &x` itself ("returning address of expired
//! local variable"); it does not refuse a slice of a local array, a pointer carried out in a
//! returned struct literal or through a local alias (`const out = &x; return out;`). Those are
//! this rule's.
//!
//! Hygiene: it reports the escape it shows and nothing else. A value whose reach is not read
//! (its address handed to a callee whose stores are not known, a value not resolved, more aliases
//! than are followed) is none, never a report. A `var` local counts, and a `const` one but where
//! its value is a literal or a `comptime` expression the program compiles in (static memory). A
//! path through a field or an element counts but where the local's type, written or of its value,
//! is a pointer, which Zig dereferences on access. Nothing inside `comptime` or in a function
//! returning `type` counts, where frames are comptime memory. A store the function undoes does
//! not outlive the call: a `defer` that assigns the target again (a registration cleared) on
//! every exit. Aliases are followed within the function, through a `const`'s value and every
//! value a `var` is given. A clean run never certifies lifetimes.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Model = @import("Model.zig");
const Rule = @import("Rule.zig").Rule;
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
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
    for (found.items) |each| {
        const node = each.node;
        const operand = each.operand;
        const stored = each.stored;
        if (c.inTest(tree.nodeMainToken(node))) continue;
        const function = self.enclosing(node) orelse continue;
        if (stored) |target| if (!try self.outlives(target)) continue;
        const reached = try self.escaping(operand, function, 0);
        if (reached == .none) continue;
        if (stored) |target| if (try self.restored(function, target, node)) continue;
        const local = switch (reached) {
            .none => unreachable, // unreachable: left above
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

/// What a pointer value reaches into: a local of the function's frame, or none shown. P009 is
/// hygiene: a value whose reach is not known is none, never a report.
const Reached = union(enum) {
    local: Model.Declaration.Id,
    none,
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
        const d, const decl = self.declared(identifier, function) orelse return null;
        return if (decl.kind == .variable) d else null;
    }

    /// The declaration of a capture an identifier names, when it is one of `function`'s own.
    fn capture(self: Walk, identifier: Ast.Node.Index, function: Ast.Node.Index) ?Model.Declaration {
        _, const decl = self.declared(identifier, function) orelse return null;
        return if (decl.kind == .capture) decl else null;
    }

    /// The declaration an identifier names, when `function`'s body declares it.
    fn declared(self: Walk, identifier: Ast.Node.Index, function: Ast.Node.Index) ?struct { Model.Declaration.Id, Model.Declaration } {
        const reference = self.model.reference(identifier) orelse return null;
        const d = reference.declaration orelse return null;
        const decl = self.model.declarations[@backingInt(d)];
        if (self.enclosing(decl.node) != function) return null;
        return .{ d, decl };
    }

    /// The local a pointer value reaches into: through `depth` aliases so far.
    fn escaping(self: Walk, written: Ast.Node.Index, function: Ast.Node.Index, depth: u8) Context.Error!Reached {
        const tree = self.tree;
        const node = Facts.ungrouped(tree, written);
        if (depth > 8) return .none;
        // A value carried or chosen (`.?`, `try`, both sides of `orelse` and `catch`, an `if`'s
        // or a `switch`'s results, a labeled block's `break`s, `@as`): each value it may give.
        switch (try Facts.accesses.valuesOf(self.c.facts, self.c.file, node)) {
            .leaves => |leaves| if (leaves.len != 1 or leaves[0] != node) return self.first(leaves, function, depth + 1),
            .unknown => return .none,
        }
        switch (tree.nodeTag(node)) {
            .address_of => return self.addressOf(tree.nodeData(node).node, function, depth),
            .slice_open, .slice, .slice_sentinel => {
                const sliced = (tree.fullSlice(node) orelse return .none).ast.sliced;
                const root = (try self.storage(sliced)) orelse return .none;
                if (root != Facts.ungrouped(tree, sliced)) return .none;
                const d = (try self.variable(root, function)) orelse return .none;
                if (try self.array(d)) return .{ .local = d };
                // A pointer's slice points where the pointer does: what the local is given, but
                // a slice of itself (`s = s[1..]`), which holds no memory it did not.
                if (try self.c.facts.holdsNoAddress(try self.typeOf(d))) return .none;
                const given = (try self.c.facts.givenTo(.{ .file = self.c.file, .index = d }, true)) orelse
                    return .none;
                var others: std.ArrayList(Facts.Key) = .empty;
                for (given) |each| if (!try self.slicesItself(each.node, d)) try others.append(self.c.allocator, each);
                return self.first(others.items, function, depth + 1);
            },
            // A name for a pointer: each value it or a part of it is given (`Facts.givenTo`),
            // what a `const` holds; a store that may give it any value may give it a local's
            // address.
            .identifier => {
                // A capture: a pointer one points into its source's memory; one by value is
                // what the source gives, a loop's each element of a literal it runs over.
                if (self.capture(node, function)) |record| {
                    const source = self.c.facts.captureSource(self.c.file, record) orelse return .none;
                    if (tree.tokenTag(record.token - 1) == .asterisk) return self.pointed(source, function, depth + 1);
                    if (try self.c.facts.holdsNoAddress(try self.c.facts.resolve(self.c.file, node))) return .none;
                    if (tree.fullFor(record.node) == null) return self.escaping(source, function, depth + 1);
                    var buffer: [2]Ast.Node.Index = undefined;
                    const literal = tree.fullArrayInit(&buffer, Facts.ungrouped(tree, source)) orelse return .none;
                    return self.first(literal.ast.elements, function, depth + 1);
                }
                const d = self.own(node, function) orelse return .none;
                // A value that holds no pointer (`[4]u8` returned whole) points nowhere.
                if (try self.c.facts.holdsNoAddress(try self.typeOf(d))) return .none;
                const given = (try self.c.facts.givenTo(.{ .file = self.c.file, .index = d }, true)) orelse
                    return .none;
                return self.first(given, function, depth + 1);
            },
            // A pointer moved by a number points into the memory it did (`p + 1`); a difference
            // of two is a number.
            .add, .sub, .add_wrap, .sub_wrap => {
                if (try self.c.facts.holdsNoAddress(try self.c.facts.resolve(self.c.file, node))) return .none;
                return self.escaping(tree.nodeData(node).node_and_node[0], function, depth + 1);
            },
            // A slice's `ptr` points where the slice does.
            .field_access => return switch (try self.c.facts.languageField(self.c.file, node)) {
                .ptr => self.escaping(tree.nodeData(node).node_and_token[0], function, depth + 1),
                .len, .none, .unknown => .none,
            },
            else => {
                // A cast of a pointer keeps its address.
                var arguments: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, node, &arguments);
                for ([_]struct { []const u8, usize }{ .{ "@ptrCast", 0 }, .{ "@alignCast", 0 }, .{ "@constCast", 0 }, .{ "@volatileCast", 0 }, .{ "@fieldParentPtr", 1 } }) |cast| {
                    if (Facts.isBuiltin(tree, node, cast[0]) and cast[1] < args.len) return self.escaping(args[cast[1]], function, depth + 1);
                }
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullStructInit(&buffer, node)) |literal| return self.first(literal.ast.fields, function, depth);
                if (tree.fullArrayInit(&buffer, node)) |literal| return self.first(literal.ast.elements, function, depth);
                return .none;
            },
        }
    }

    /// The local the address of the place `inner` points into.
    fn addressOf(self: Walk, inner: Ast.Node.Index, function: Ast.Node.Index, depth: u8) Context.Error!Reached {
        // A place reached through a pointer (`&p.*`, `&p.f`, `&s[i]`) is in the memory that
        // pointer points at.
        if (try self.crossed(inner)) |pointer| return self.escaping(pointer, function, depth + 1);
        const root = (try self.storage(inner)) orelse return .none;
        // The local itself is its frame's memory, whatever its type.
        if (root == Facts.ungrouped(self.tree, inner)) return reach(try self.variable(root, function));
        const d = (try self.variable(root, function)) orelse return .none;
        return if (try self.value(d)) .{ .local = d } else .none;
    }

    /// The local a pointer capture (`|*v|`) points into: the memory its source points at (a
    /// slice, a pointer to an array), or the source's own where it holds what it captures (an
    /// optional, a union, an array). A source whose type is not known shows neither: none.
    fn pointed(self: Walk, source: Ast.Node.Index, function: Ast.Node.Index, depth: u8) Context.Error!Reached {
        const typed = try self.c.facts.resolve(self.c.file, source);
        var pointer = false;
        var holder = false;
        for (Facts.valueParts(&typed)) |part| switch (part) {
            .pointer => pointer = true,
            .unknown, .alternatives => {},
            else => holder = true,
        };
        if (pointer) {
            const out = try self.escaping(source, function, depth);
            if (out == .local) return out;
        }
        if (holder) return self.addressOf(source, function, depth);
        return .none;
    }

    /// The pointer the place `node` is reached through nearest to it, whose memory holds the
    /// place (`p` of `p.*`, `p.f`, `p[i]`, `s[i]` of a slice); null where no step crosses one.
    fn crossed(self: Walk, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
        const path = try Facts.accesses.pathOf(self.c.facts, self.c.file, node);
        // The root crosses none.
        for (path.steps) |step| if (step.crosses) return switch (step.kind) {
            .field => step.receiver,
            .index => self.tree.nodeData(step.node).node_and_node[0],
            .slice => (self.tree.fullSlice(step.node) orelse return null).ast.sliced,
            .deref => self.tree.nodeData(step.node).node,
            .unwrap, .root => null,
        };
        return null;
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

    /// The first local one of `values` (expressions, or `Facts.Key`s of this file) reaches
    /// into, or none.
    fn first(self: Walk, values: anytype, function: Ast.Node.Index, depth: u8) Context.Error!Reached {
        for (values) |each| switch (try self.escaping(if (@TypeOf(each) == Facts.Key) each.node else each, function, depth)) {
            .local => |d| return .{ .local = d },
            .none => {},
        };
        return .none;
    }

    fn reach(local: ?Model.Declaration.Id) Reached {
        return if (local) |d| .{ .local = d } else .none;
    }

    /// A local of `function`'s own in its frame: a `var` not comptime, or a `const` whose value
    /// is not one the program compiles in (`compiledIn`).
    fn variable(self: Walk, identifier: Ast.Node.Index, function: Ast.Node.Index) Context.Error!?Model.Declaration.Id {
        const d = self.own(identifier, function) orelse return null;
        const decl = self.tree.fullVarDecl(self.model.declarations[@backingInt(d)].node) orelse return null;
        if (decl.comptime_token != null) return null;
        if (self.tree.tokenTag(decl.ast.mut_token) == .keyword_const) {
            const init = decl.ast.init_node.unwrap() orelse return null;
            if (try self.compiledIn(self.c.file, init, 0)) return null;
        }
        return d;
    }

    /// Whether a value of `file` is one the program compiles in, so a `const` holding it is
    /// static memory: a literal (a number, a character, a string, an enum literal, an array or
    /// struct literal of such values, a concatenation of them), `comptime x`, `true`, `false`,
    /// `null`, a comptime parameter, a declaration of a file or container, a local `const` of
    /// such a value, arithmetic and negation of such values, and a call of an `inline fn` given
    /// only such values (`std.math.inf(T)`, which Zig evaluates as it compiles).
    fn compiledIn(self: Walk, file: Project.FileId, written: Ast.Node.Index, depth: u8) Context.Error!bool {
        if (depth == 8) return false;
        const tree = &self.c.project.at(file).file.tree;
        const node = Facts.ungrouped(tree, written);
        switch (tree.nodeTag(node)) {
            .number_literal, .char_literal, .string_literal, .multiline_string_literal, .enum_literal => return true,
            .@"comptime" => return true,
            .array_cat, .add, .sub, .mul, .div, .mod, .shl, .shr, .bit_and, .bit_or, .bit_xor, .add_wrap, .sub_wrap, .mul_wrap => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                return try self.compiledIn(file, lhs, depth + 1) and try self.compiledIn(file, rhs, depth + 1);
            },
            .negation, .negation_wrap, .bit_not => return self.compiledIn(file, tree.nodeData(node).node, depth + 1),
            .identifier => {
                const spelled = tree.tokenSlice(tree.nodeMainToken(node));
                for ([_][]const u8{ "true", "false", "null" }) |each| if (std.mem.eql(u8, spelled, each)) return true;
                return self.declaredIn(try self.c.facts.definition(file, node), depth);
            },
            .field_access => return self.declaredIn(try self.c.facts.definition(file, node), depth),
            else => {},
        }
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullArrayInit(&buffer, node)) |literal| {
            for (literal.ast.elements) |element| if (!try self.compiledIn(file, element, depth + 1)) return false;
            return true;
        }
        if (tree.fullStructInit(&buffer, node)) |literal| {
            for (literal.ast.fields) |field| if (!try self.compiledIn(file, field, depth + 1)) return false;
            return true;
        }
        var call_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&call_buffer, node)) |call| {
            const found = (try Facts.calls.at(self.c.facts, file, node)) orelse return false;
            const callee = switch (found.callee) {
                .function => |function| function,
                .choice, .any => return false,
            };
            const target = &self.c.project.at(callee.file).file.tree;
            var proto_buffer: [1]Ast.Node.Index = undefined;
            const proto = target.fullFnProto(&proto_buffer, self.c.project.at(callee.file).model.declarations[@backingInt(callee.index)].node) orelse return false;
            const keyword = proto.extern_export_inline_token orelse return false;
            if (target.tokenTag(keyword) != .keyword_inline) return false;
            for (call.ast.params) |argument| if (!try self.compiledIn(file, argument, depth + 1)) return false;
            return true;
        }
        return false;
    }

    /// Whether what a name refers to holds a value the program compiles in.
    fn declaredIn(self: Walk, named: Facts.Named, depth: u8) Context.Error!bool {
        const decl = switch (named) {
            .decl => |decl| decl,
            .none, .unknown => return false,
        };
        const model = &self.c.project.at(decl.file).model;
        const tree = &self.c.project.at(decl.file).file.tree;
        const record = model.declarations[@backingInt(decl.index)];
        switch (record.kind) {
            .parameter => return record.token > 0 and tree.tokenTag(record.token - 1) == .keyword_comptime,
            .variable => {},
            .function, .field, .capture => return false,
        }
        const holder = tree.fullVarDecl(record.node) orelse return false;
        if (tree.tokenTag(holder.ast.mut_token) != .keyword_const) return false;
        switch (model.scopes[@backingInt(record.scope)].kind) {
            .file, .container => return true,
            else => {},
        }
        const init = holder.ast.init_node.unwrap() orelse return false;
        return self.compiledIn(decl.file, init, depth + 1);
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
        if (self.parameter(root) or self.global(root)) return true;
        // A place through a local's pointer is in the memory that pointer is given: a place
        // that outlives the call, or what a parameter's or a container variable's points at.
        const pointer = (try self.crossed(target)) orelse return false;
        if (try Facts.accesses.pointed(self.c.facts, self.c.file, pointer)) |place| return place != target and try self.outlives(place);
        const memory = try Facts.accesses.viewed(self.c.facts, self.c.file, pointer);
        const reached = try Facts.accesses.pathOf(self.c.facts, self.c.file, memory);
        if (reached.root != .decl) return false;
        const base = reached.steps[reached.steps.len - 1].node;
        return self.parameter(base) or self.global(base);
    }

    fn parameter(self: Walk, identifier: Ast.Node.Index) bool {
        const reference = self.model.reference(identifier) orelse return false;
        const d = reference.declaration orelse return false;
        return self.model.declarations[@backingInt(d)].kind == .parameter;
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
    /// registration cleared on every exit before the frame goes. A store a `defer` makes itself
    /// is undone only by one that runs after it: declared before it, in a block that holds it.
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
            for (statements) |statement| for (try Facts.accesses.storesIn(self.c.facts, self.c.file)) |site| {
                if (site.node != statement or site.kind != .set) continue;
                const written = site.target orelse continue;
                if (try Facts.accesses.samePlace(self.c.facts, self.c.file, written, target) == .yes) return true;
            };
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
