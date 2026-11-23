//! P009 (0.8): a pointer into a function's own frame carried out of the call, reported only where
//! certain: by its `return`, or by a store to a place that outlives the call (a container's
//! variable, memory a parameter points at), an atomic store's included, or by a callee it is
//! handed to that stores it so (its own store of the parameter into a container's variable, or
//! Facts' `storesAddress` through another argument that outlives the call).
//!
//! A `var` declared in a function's body lives in the call's frame, which the return frees.
//! Its address (`&x`, `&x.field`, `&x[i]`), or a slice of it when it is an array (`x[a..b]`),
//! is a pointer into that frame. Zig refuses `return &x` itself ("returning address of expired
//! local variable"); it does not refuse a slice of a local array, a pointer carried out in a
//! returned struct literal or through a local alias (`const out = &x; return out;`). Those are
//! this rule's.
//!
//! A local returned by value carries what was stored into its own memory, by any name for it
//! (`into.* = &x` of `const into = &p`, a `|*r|` capture's `r.buffer = &local`, a method that
//! stores its argument through its receiver); a call's result, an argument the callee returns
//! (`same(&x)`); a destructured name, its element of the literal.
//!
//! Hygiene: it reports the escape it shows and nothing else. A value whose reach is not read
//! (its address handed to a callee whose stores are not known, a value not resolved, more aliases
//! than are followed) is none, never a report. A `var` local counts, and a `const` one but where
//! its value is a literal or a `comptime` expression the program compiles in (static memory). A
//! path through a field or an element counts but where the local's type, written or of its value,
//! is a pointer, which Zig dereferences on access. Nothing inside `comptime` or in a function
//! returning `type` counts, where frames are comptime memory. A store the function undoes does
//! not outlive the call: a `defer` that assigns the target again (a registration cleared) on
//! every exit, or one that names the local (it may unlink the address: not certain). A callee
//! keeps what it stores of the pointer itself; what it reads through the pointer
//! is the pointed memory's (`e.next = out.*` keeps what `room` holds, not `&room`). Aliases are
//! followed within the function, through a `const`'s value and every value a `var` is given. A
//! clean run never certifies lifetimes.
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
    var memo: Memo = .{};
    const self: Walk = .{ .c = c, .tree = tree, .model = model, .memo = &memo };
    var found: std.ArrayList(Found) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        try found.append(c.allocator, .{ .node = node, .operand = tree.nodeData(node).opt_node.unwrap() orelse continue, .stored = null });
    }
    // A store of a value into a place: kept where the place outlives the call (`outlives`), an
    // atomic store's included (`@atomicStore(?*u32, &current, &x, .release)`).
    for (try Facts.accesses.storesIn(c.facts, c.file)) |site| {
        if (site.kind != .set) continue;
        const target = Facts.ungrouped(tree, site.target orelse continue);
        const place = if (tree.nodeTag(target) == .address_of) tree.nodeData(target).node else target;
        try found.append(c.allocator, .{ .node = site.node, .operand = site.value orelse continue, .stored = place });
    }
    // A builtin that stores a value through a pointer it is given (`@atomicStore(?*u32,
    // &current, &x, .release)`): the place the pointer points at takes the value.
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .builtin_call, .builtin_call_comma => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var arguments: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &arguments);
        for ([_]struct { []const u8, usize }{ .{ "@atomicStore", 2 }, .{ "@cmpxchgWeak", 3 }, .{ "@cmpxchgStrong", 3 } }) |writer| {
            if (!Facts.isBuiltin(tree, node, writer[0]) or writer[1] >= args.len) continue;
            const pointer = Facts.ungrouped(tree, args[1]);
            if (tree.nodeTag(pointer) != .address_of) continue;
            try found.append(c.allocator, .{ .node = node, .operand = args[writer[1]], .stored = tree.nodeData(pointer).node });
        }
    }
    // A call that hands a local's address to a callee storing it where it outlives the call.
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .call, .call_comma, .call_one, .call_one_comma => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (c.inTest(tree.nodeMainToken(node))) continue;
        const function = self.enclosing(node) orelse continue;
        if (try self.handedOut(node, function)) |escape| {
            const name = model.declarations[@backingInt(escape.local)].name;
            try c.at(rule, tree.nodeMainToken(escape.argument), try c.allocator.print("hands a pointer into local '{s}' to a callee that stores it where it outlives the call that frees it", .{name}));
        }
    }
    for (found.items) |each| {
        const node = each.node;
        const operand = each.operand;
        const stored = each.stored;
        if (c.inTest(tree.nodeMainToken(node))) continue;
        const function = self.enclosing(node) orelse continue;
        if (stored) |target| if (!try self.outlives(target)) continue;
        const reached = try self.escaping(operand, function);
        if (reached == .none) continue;
        if (stored) |target| if (try self.restored(function, target, node) or self.unlinked(function, node, reached)) continue;
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

/// What a check's walk has found, each once: a value's reach by its node, the reach of what is
/// stored into a local by the local, and each function's stores and calls.
///
/// A value or local met again while its own reach is being found is met through a cycle, and is
/// assumed to reach none, what a finite run of its stores makes. What is found under that
/// assumption is kept only while it holds: where the value assumed comes out reaching none, each
/// reach found under it stands; where it comes out reaching a local, they are dropped, and found
/// again when next asked, the value's own reach then known (`Walk.findOnce`).
const Memo = struct {
    reached: std.AutoHashMapUnmanaged(Key, State) = .empty,
    stored: std.AutoHashMapUnmanaged(Model.Declaration.Id, State) = .empty,
    parts: ?std.AutoHashMapUnmanaged(Ast.Node.Index, Parts) = null,
    /// How many findings are open, each one's depth its place among them.
    open: usize = 0,
    /// The shallowest open finding one met again since the innermost began.
    low: usize = std.math.maxInt(usize),
    /// What was found under an assumption about one still open.
    provisional: std.ArrayList(Entry) = .empty,

    const Key = struct { node: Ast.Node.Index, function: Ast.Node.Index };
    const State = union(enum) { reading: usize, read: Reached };
    const Which = enum { reached, stored };
    const Entry = union(Which) { reached: Key, stored: Model.Declaration.Id };
    /// A function's stores of a value (`Facts.accesses.storesIn`'s sets) and its calls.
    const Parts = struct { sites: std.ArrayList(Facts.accesses.Site) = .empty, calls: std.ArrayList(Ast.Node.Index) = .empty };
};

const Walk = struct {
    c: *Context,
    tree: *const Ast,
    model: *const Model,
    memo: *Memo,

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

    /// The local a pointer value reaches into, found once for the check (`Memo`). Each value's
    /// reach found is one of the file's resolutions, so the walk ends within the fact budget,
    /// whatever the function's size: past it, the file's analysis is refused as short of budget.
    fn escaping(self: Walk, written: Ast.Node.Index, function: Ast.Node.Index) Context.Error!Reached {
        return self.findOnce(.{ .reached = .{ .node = Facts.ungrouped(self.tree, written), .function = function } }, function);
    }

    /// The reach `entry` names, found once as `Memo` keeps it: met again while open, assumed
    /// none; found under an assumption about an open one, kept as long as that one reaches none.
    fn findOnce(self: Walk, entry: Memo.Entry, function: Ast.Node.Index) Context.Error!Reached {
        const a = self.c.allocator;
        const memo = self.memo;
        const known = switch (entry) {
            .reached => |key| memo.reached.get(key),
            .stored => |d| memo.stored.get(d),
        };
        if (known) |state| switch (state) {
            .read => |kept| return kept,
            .reading => |depth| {
                memo.low = @min(memo.low, depth);
                return .none;
            },
        };
        // Each reach found is one of the file's resolutions: past the budget, none, and the
        // file's analysis is short.
        if (self.c.facts.budgetSpent()) return .none;
        self.c.facts.remaining -= 1;
        const depth = memo.open;
        try self.keep(entry, .{ .reading = depth });
        memo.open += 1;
        const outer_low = memo.low;
        memo.low = std.math.maxInt(usize);
        const kept_before = memo.provisional.items.len;
        const reached = switch (entry) {
            .reached => |key| try self.reaching(key.node, function),
            .stored => |d| try self.storedOnce(d, function),
        };
        memo.open -= 1;
        const low = memo.low;
        memo.low = @min(outer_low, low);
        try self.keep(entry, .{ .read = reached });
        if (low < depth) {
            // Found under an assumption about one further out: it stands or falls with that one.
            try memo.provisional.append(a, entry);
        } else if (memo.provisional.items.len > kept_before) {
            // Its own assumption, none: held where it comes out none.
            if (reached != .none) for (memo.provisional.items[kept_before..]) |undone| switch (undone) {
                .reached => |key| _ = memo.reached.remove(key),
                .stored => |d| _ = memo.stored.remove(d),
            };
            memo.provisional.shrinkRetainingCapacity(kept_before);
        }
        return reached;
    }

    fn keep(self: Walk, entry: Memo.Entry, state: Memo.State) Context.Error!void {
        switch (entry) {
            .reached => |key| try self.memo.reached.put(self.c.allocator, key, state),
            .stored => |d| try self.memo.stored.put(self.c.allocator, d, state),
        }
    }

    /// The local `node`, a value of `function`, reaches into, as `escaping` finds it.
    fn reaching(self: Walk, node: Ast.Node.Index, function: Ast.Node.Index) Context.Error!Reached {
        const tree = self.tree;
        // A value carried or chosen (`.?`, `try`, both sides of `orelse` and `catch`, an `if`'s
        // or a `switch`'s results, a labeled block's `break`s, `@as`): each value it may give.
        switch (try Facts.accesses.valuesOf(self.c.facts, self.c.file, node)) {
            .leaves => |leaves| if (leaves.len != 1 or leaves[0] != node) return self.first(leaves, function),
            .unknown => return .none,
        }
        switch (tree.nodeTag(node)) {
            .address_of => return self.addressOf(tree.nodeData(node).node, function),
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
                return self.first(others.items, function);
            },
            // A name for a pointer: each value it or a part of it is given (`Facts.givenTo`),
            // what a `const` holds; a store that may give it any value may give it a local's
            // address.
            .identifier => {
                // A capture: a pointer one points into its source's memory; one by value is
                // what the source gives, a loop's each element of a literal it runs over.
                if (self.capture(node, function)) |record| {
                    const source = self.c.facts.captureSource(self.c.file, record) orelse return .none;
                    if (tree.tokenTag(record.token - 1) == .asterisk) return self.pointed(source, function);
                    if (try self.c.facts.holdsNoAddress(try self.c.facts.resolve(self.c.file, node))) return .none;
                    if (tree.fullFor(record.node) == null) return self.escaping(source, function);
                    var buffer: [2]Ast.Node.Index = undefined;
                    const literal = tree.fullArrayInit(&buffer, Facts.ungrouped(tree, source)) orelse return .none;
                    return self.first(literal.ast.elements, function);
                }
                const d = self.own(node, function) orelse return .none;
                // A name a destructure declares holds its element of the literal destructured.
                if (self.destructuredElement(d)) |element| return self.escaping(element, function);
                // A value that holds no pointer (`[4]u8` returned whole) points nowhere.
                if (try self.c.facts.holdsNoAddress(try self.typeOf(d))) return .none;
                // What a store put into its own memory, by any name for it (`into.* = &x` of
                // `const into = &p`, a `|*r|` capture's `r.buffer = &local`, a method that stores
                // its argument through its receiver).
                const stored = try self.storedInto(d, function);
                if (stored == .local) return stored;
                const given = (try self.c.facts.givenTo(.{ .file = self.c.file, .index = d }, true)) orelse
                    return .none;
                return self.first(given, function);
            },
            // A pointer moved by a number points into the memory it did (`p + 1`); a difference
            // of two is a number.
            .add, .sub, .add_wrap, .sub_wrap => {
                if (try self.c.facts.holdsNoAddress(try self.c.facts.resolve(self.c.file, node))) return .none;
                return self.escaping(tree.nodeData(node).node_and_node[0], function);
            },
            // A slice's `ptr` points where the slice does.
            .field_access => return switch (try self.c.facts.languageField(self.c.file, node)) {
                .ptr => self.escaping(tree.nodeData(node).node_and_token[0], function),
                .len, .none, .unknown => .none,
            },
            else => {
                // A cast of a pointer keeps its address.
                var arguments: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, node, &arguments);
                for ([_]struct { []const u8, usize }{ .{ "@ptrCast", 0 }, .{ "@alignCast", 0 }, .{ "@constCast", 0 }, .{ "@volatileCast", 0 }, .{ "@fieldParentPtr", 1 } }) |cast| {
                    if (Facts.isBuiltin(tree, node, cast[0]) and cast[1] < args.len) return self.escaping(args[cast[1]], function);
                }
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullStructInit(&buffer, node)) |literal| return self.first(literal.ast.fields, function);
                if (tree.fullArrayInit(&buffer, node)) |literal| return self.first(literal.ast.elements, function);
                // A call's result holds what the callee returns of an argument (`same(&x)`).
                var call_buffer: [1]Ast.Node.Index = undefined;
                if (tree.fullCall(&call_buffer, node) != null) return self.returned(node, function);
                return .none;
            },
        }
    }

    /// The local the address of the place `inner` points into.
    fn addressOf(self: Walk, inner: Ast.Node.Index, function: Ast.Node.Index) Context.Error!Reached {
        // A place reached through a pointer (`&p.*`, `&p.f`, `&s[i]`) is in the memory that
        // pointer points at.
        if (try self.crossed(inner)) |pointer| return self.escaping(pointer, function);
        const root = (try self.storage(inner)) orelse return .none;
        // The local itself is its frame's memory, whatever its type.
        if (root == Facts.ungrouped(self.tree, inner)) return reach(try self.variable(root, function));
        const d = (try self.variable(root, function)) orelse return .none;
        return if (try self.value(d)) .{ .local = d } else .none;
    }

    /// The local a pointer capture (`|*v|`) points into: the memory its source points at (a
    /// slice, a pointer to an array), or the source's own where it holds what it captures (an
    /// optional, a union, an array). A source whose type is not known shows neither: none.
    fn pointed(self: Walk, source: Ast.Node.Index, function: Ast.Node.Index) Context.Error!Reached {
        const typed = try self.c.facts.resolve(self.c.file, source);
        var pointer = false;
        var holder = false;
        for (Facts.valueParts(&typed)) |part| switch (part) {
            .pointer => pointer = true,
            .unknown, .alternatives => {},
            else => holder = true,
        };
        if (pointer) {
            const out = try self.escaping(source, function);
            if (out == .local) return out;
        }
        if (holder) return self.addressOf(source, function);
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
    fn first(self: Walk, values: anytype, function: Ast.Node.Index) Context.Error!Reached {
        for (values) |each| switch (try self.escaping(if (@TypeOf(each) == Facts.Key) each.node else each, function)) {
            .local => |d| return .{ .local = d },
            .none => {},
        };
        return .none;
    }

    fn reach(local: ?Model.Declaration.Id) Reached {
        return if (local) |d| .{ .local = d } else .none;
    }

    /// A call whose callee and arguments are known: each function it may call, its arguments
    /// (the receiver first where one is bound, as the callee's first parameter).
    const Called = struct { functions: []const Facts.Decl, args: []const Ast.Node.Index, receiver: bool };

    fn callOf(self: Walk, call: Ast.Node.Index) Context.Error!?Called {
        const found = (try Facts.calls.at(self.c.facts, self.c.file, call)) orelse return null;
        const args = switch (found.args) {
            .known => |each| each,
            .unknown => return null,
        };
        const functions: []const Facts.Decl = switch (found.callee) {
            .function => |one| try self.c.allocator.dupe(Facts.Decl, &.{one}),
            .choice => |each| each,
            .any => return null,
        };
        return .{ .functions = functions, .args = args, .receiver = found.receiver == .bound };
    }

    /// What a callee does with an argument, as Facts reads its body: returns it, stores it or
    /// what is read through it into the memory another parameter points at (`param`), or stores
    /// it alone there (`pointer`).
    const Use = union(enum) { result: usize, param: Between, pointer: Between };
    const Between = struct { into: usize, from: usize };

    /// Whether every function of a call does so, certainly (P009 reports only what it shows).
    fn every(self: Walk, functions: []const Facts.Decl, use: Use) Context.Error!bool {
        for (functions) |function| {
            const does = switch (use) {
                .result => |from| try self.c.facts.returnsAddress(function, from, false),
                .param => |p| try self.c.facts.storesAddress(function, p.into, p.from),
                .pointer => |p| try self.c.facts.storesPointer(function, p.into, p.from),
            };
            if (does != true) return false;
        }
        return functions.len != 0;
    }

    /// The local a call's result reaches into: an argument that does, which the callee returns
    /// (`same(&x)` of `fn same(p: *u32) *u32 { return p; }`).
    fn returned(self: Walk, call: Ast.Node.Index, function: Ast.Node.Index) Context.Error!Reached {
        const read = (try self.callOf(call)) orelse return .none;
        for (read.args, 0..) |arg, from| {
            const reached = try self.escaping(arg, function);
            if (reached == .local and try self.every(read.functions, .{ .result = from })) return reached;
        }
        return .none;
    }

    /// The element of a destructured literal a name declares (`const p, const n = .{ &x, 0 }`);
    /// null where the name is no destructure's or its value is no literal.
    fn destructuredElement(self: Walk, d: Model.Declaration.Id) ?Ast.Node.Index {
        const node = self.model.declarations[@backingInt(d)].node;
        const parent = self.model.parentOf(node) orelse return null;
        if (self.tree.nodeTag(parent) != .assign_destructure) return null;
        const whole = self.tree.assignDestructure(parent);
        const position = std.mem.findScalar(Ast.Node.Index, whole.ast.variables, node) orelse return null;
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = self.tree.fullArrayInit(&buffer, Facts.ungrouped(self.tree, whole.ast.value_expr)) orelse return null;
        if (position >= literal.ast.elements.len) return null;
        return literal.ast.elements[position];
    }

    /// The local, another than `d`, a pointer stored into `d`'s own memory reaches: a store into
    /// it or a part of it by any name (`into.* = &x` of `const into = &p`, `r.buffer = &local` of
    /// a `|*r|` capture of `d`), or a call that stores an argument through `d` (a method on it,
    /// `map.put(&name, v)`, or `d`'s address handed in).
    fn storedInto(self: Walk, d: Model.Declaration.Id, function: Ast.Node.Index) Context.Error!Reached {
        return self.findOnce(.{ .stored = d }, function);
    }

    fn storedOnce(self: Walk, d: Model.Declaration.Id, function: Ast.Node.Index) Context.Error!Reached {
        const parts = try self.partsOf(function);
        for (parts.sites) |site| {
            const given = site.value orelse continue;
            if (!try self.inMemoryOf(site.target orelse continue, d, function)) continue;
            const reached = try self.escaping(given, function);
            if (reached == .local and reached.local != d) return reached;
        }
        for (parts.calls) |call| {
            const read = (try self.callOf(call)) orelse continue;
            for (read.args, 0..) |holder, into| {
                // A receiver is handed by its address; any other argument by its value, whose
                // pointer is `d`'s memory only where it points into it.
                const held = if (into == 0 and read.receiver) self.own(Facts.ungrouped(self.tree, holder), function) == d else blk: {
                    const points = try self.escaping(holder, function);
                    break :blk points == .local and points.local == d;
                };
                if (!held) continue;
                for (read.args, 0..) |_, from| {
                    if (from == into) continue;
                    const reached = try self.carried(read, .{ .into = into, .from = from }, function);
                    if (reached == .local and reached.local != d) return reached;
                }
            }
        }
        return .none;
    }

    /// `function`'s stores of a value and its calls, gathered for every function of the file in
    /// one pass the first time one is asked for.
    fn partsOf(self: Walk, function: Ast.Node.Index) Context.Error!struct { sites: []const Facts.accesses.Site, calls: []const Ast.Node.Index } {
        const a = self.c.allocator;
        if (self.memo.parts == null) {
            var gathered: std.AutoHashMapUnmanaged(Ast.Node.Index, Memo.Parts) = .empty;
            for (try Facts.accesses.storesIn(self.c.facts, self.c.file)) |site| {
                if (site.kind != .set) continue;
                const holder = self.enclosing(site.node) orelse continue;
                const entry = try gathered.getOrPut(a, holder);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                try entry.value_ptr.sites.append(a, site);
            }
            for (self.tree.nodes.items(.tag), 0..) |tag, i| {
                switch (tag) {
                    .call, .call_comma, .call_one, .call_one_comma => {},
                    else => continue,
                }
                const call: Ast.Node.Index = @fromBackingInt(@intCast(i));
                const holder = self.enclosing(call) orelse continue;
                const entry = try gathered.getOrPut(a, holder);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                try entry.value_ptr.calls.append(a, call);
            }
            self.memo.parts = gathered;
        }
        const parts = self.memo.parts.?.get(function) orelse return .{ .sites = &.{}, .calls = &.{} };
        return .{ .sites = parts.sites.items, .calls = parts.calls.items };
    }

    /// Whether the place `target` lies in `d`'s own memory: `d` or a part of it by its name, or
    /// a place a pointer into `d` reaches.
    fn inMemoryOf(self: Walk, target: Ast.Node.Index, d: Model.Declaration.Id, function: Ast.Node.Index) Context.Error!bool {
        if (try self.crossed(target)) |pointer| {
            const into = try self.escaping(pointer, function);
            return into == .local and into.local == d;
        }
        const root = (try self.storage(target)) orelse return false;
        return self.own(root, function) == d;
    }

    /// A local's address a call hands to a callee that stores it where it outlives the call:
    /// into a container's variable, by the callee's own store of its parameter (`registered =
    /// p`), or into the memory another argument outlives the call in (a parameter's, a
    /// container variable's).
    fn handedOut(self: Walk, call: Ast.Node.Index, function: Ast.Node.Index) Context.Error!?Handed {
        const read = (try self.callOf(call)) orelse return null;
        for (read.args, 0..) |arg, from| {
            const reached = try self.escaping(arg, function);
            if (reached == .local and try self.everyStoresGlobally(read.functions, from)) return .{ .local = reached.local, .argument = arg };
            for (read.args, 0..) |holder, into| {
                if (into == from or !try self.outlivingPointer(holder)) continue;
                const kept = try self.carried(read, .{ .into = into, .from = from }, function);
                if (kept == .local) return .{ .local = kept.local, .argument = arg };
            }
        }
        return null;
    }

    /// The local a call keeps a pointer into, in the memory its argument at `into` points at, of
    /// what it is handed at `from`: the argument's own pointer, where every callee stores it
    /// there; else the pointer the local it is the address of holds (`&room` of `var room =
    /// buf`), where every callee stores what it reads through the argument (`e.next =
    /// out.*`). A value read through a pointer is the pointed memory's, never the pointer
    /// (std.mem.swap of `&j`, review b9 C2 and C3).
    fn carried(self: Walk, read: Called, between: Between, function: Ast.Node.Index) Context.Error!Reached {
        const arg = read.args[between.from];
        const reached = try self.escaping(arg, function);
        if (reached == .local and try self.every(read.functions, .{ .pointer = between })) return reached;
        const loaded = try self.loadedThrough(arg, function);
        if (loaded == .local and try self.every(read.functions, .{ .param = between })) return loaded;
        return .none;
    }

    /// The local what is read through `arg` reaches: of `&x`, `x`'s own name being the place,
    /// what `x` holds. Any other pointer's memory is not followed: none.
    fn loadedThrough(self: Walk, arg: Ast.Node.Index, function: Ast.Node.Index) Context.Error!Reached {
        const node = Facts.ungrouped(self.tree, arg);
        if (self.tree.nodeTag(node) != .address_of) return .none;
        const inner = Facts.ungrouped(self.tree, self.tree.nodeData(node).node);
        if (self.tree.nodeTag(inner) != .identifier or self.own(inner, function) == null) return .none;
        return self.escaping(inner, function);
    }

    /// A local's address a call hands out, and the argument that carries it.
    const Handed = struct { local: Model.Declaration.Id, argument: Ast.Node.Index };

    /// Whether an argument is a pointer to memory that outlives the call: a parameter of the
    /// caller, or the address of (or a receiver that is) a container's variable.
    fn outlivingPointer(self: Walk, holder: Ast.Node.Index) Context.Error!bool {
        const node = Facts.ungrouped(self.tree, holder);
        if (self.tree.nodeTag(node) == .address_of) return self.outlives(self.tree.nodeData(node).node);
        if (self.tree.nodeTag(node) != .identifier) return false;
        return self.parameter(node) or self.global(node);
    }

    /// Whether each function stores its parameter at `from` itself into a container's
    /// variable (`registered = p`), by a store in its own body.
    fn everyStoresGlobally(self: Walk, functions: []const Facts.Decl, from: usize) Context.Error!bool {
        for (functions) |function| if (!try self.storesGlobally(function, from)) return false;
        return functions.len != 0;
    }

    fn storesGlobally(self: Walk, function: Facts.Decl, from: usize) Context.Error!bool {
        const facts = self.c.facts;
        const tree = &self.c.project.at(function.file).file.tree;
        const model = &self.c.project.at(function.file).model;
        const record = model.declarations[@backingInt(function.index)];
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, record.node) orelse return false;
        var it = proto.iterate(tree);
        var position: usize = 0;
        const token = while (it.next()) |param| : (position += 1) {
            if (position == from) break param.name_token orelse return false;
        } else return false;
        const body = model.parentOf(record.node) orelse return false;
        for (try Facts.accesses.storesIn(facts, function.file)) |site| {
            if (site.kind != .set) continue;
            const at = tree.nodeMainToken(site.node);
            if (at < tree.firstToken(body) or at > tree.lastToken(body)) continue;
            const given = Facts.ungrouped(tree, site.value orelse continue);
            if (tree.nodeTag(given) != .identifier) continue;
            const named = (model.reference(given) orelse continue).declaration orelse continue;
            if (model.declarations[@backingInt(named)].token != token) continue;
            const path = try Facts.accesses.pathOf(facts, function.file, site.target orelse continue);
            if (path.root != .decl) continue;
            const root = (model.reference(path.steps[path.steps.len - 1].node) orelse continue).declaration orelse continue;
            if (Facts.accesses.global(facts, .{ .file = function.file, .index = root })) return true;
        }
        return false;
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
    /// `null`, a comptime parameter, a `comptime` variable, a declaration of a file or container,
    /// a local `const` of such a value, arithmetic and negation of such values, and a call of an `inline fn` given
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
        // A `comptime var` or `comptime const` lives as the program compiles: what it holds is
        // compiled in, and a const copied from it is too (lookout's `sep`, 8i).
        if (holder.comptime_token != null) return true;
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
    /// known, and no pointer Zig would dereference. A type the reading does not know may be a
    /// pointer (a slice an allocator made, through a generic context): not shown, so none.
    fn value(self: Walk, d: Model.Declaration.Id) Context.Error!bool {
        // A value where any build's type is one known to be.
        const typed = try self.typeOf(d);
        var each: Facts.Join = .{};
        for (Facts.valueParts(&typed)) |part| each.add(part, switch (part) {
            .pointer => false,
            .unknown, .alternatives => null, // not known (a choice is never a part: valueParts)
            else => true,
        });
        return each.any() orelse false;
    }

    /// Whether a local is an array a slice of which is its frame's memory: its type, written
    /// or of its value, is one. A type the reading does not know may be a slice (what an
    /// allocator made, through a generic context): not shown, so none.
    fn array(self: Walk, d: Model.Declaration.Id) Context.Error!bool {
        // An array where any build's type is one.
        const typed = try self.typeOf(d);
        for (Facts.valueParts(&typed)) |part| switch (part) {
            .array => return true,
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

    /// Whether a `defer` of `function` that runs after the store names the local: one that may
    /// unlink its address before the frame goes (`while (link.* != &waiter) ...; link.* =
    /// waiter.next;`, aegis Condition's waiter, review b9 C1). Hygiene reports only what is
    /// certain, and such an escape is not.
    fn unlinked(self: Walk, function: Ast.Node.Index, store: Ast.Node.Index, reached: Reached) bool {
        const local = switch (reached) {
            .local => |d| d,
            .none => return false,
        };
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
