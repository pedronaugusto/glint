//! A006: recursion reachable from untrusted input without a depth bound. Input an attacker
//! shapes can nest as deep as it likes, and each level of a recursive parser takes stack: the
//! program overflows it instead of refusing the input.
//!
//! Untrusted input is aegis's `input.Untrusted`: a function of the program that takes one as a
//! parameter, or that a program passes to an untrusted value's `parse` as its parser, is an
//! entry. From each entry the walk follows calls that resolve to the program's own functions
//! (std and aegis aside). A call cycle it reaches is bounded when one function on it changes
//! a depth it compares: a parameter it compares and passes on the cycle as `p + k` or `p - k`,
//! or a field it compares and moves with `+=` or `-=`, itself or through a function it calls.
//! A comparison with a length (`at < bytes.len`) is a position in the input, not a bound.
//! A bound kept further away, such as in an aegis `Budget`, is not seen, so the site is
//! reported and a written suppression names it. A call that does not resolve leaves what it
//! reaches undecided; the walk records how many such calls an entry reaches.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Contract = @import("AegisContract.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Report = @import("Report.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;

/// One function's own calls: those whose nearest enclosing function it is.
const Calls = std.AutoHashMapUnmanaged(u32, std.ArrayList(Ast.Node.Index));

const Walk = struct {
    c: *Context,
    rule: Rule,
    /// Per file, the calls of each function by its `fn_decl` node.
    calls: std.AutoHashMapUnmanaged(u32, Calls) = .empty,
    /// The functions on the current path, and the call each makes to the next.
    stack: std.ArrayList(Facts.Decl) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    done: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty,
    unresolved: u32 = 0,
    reported: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty,

    const Edge = struct { at: Facts.Decl, call: Ast.Node.Index };
};

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = try c.project.syntax(try c.source());
    const model = &c.project.models[c.file.raw()]; // safe: the checked handle indexes this frozen file.
    var walk: Walk = .{ .c = c, .rule = rule };
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .function) continue;
        if (!try takesUntrusted(c, tree, decl.node)) continue;
        try entry(&walk, .{ .file = c.file, .index = @intCast(d) }, decl.token);
    }
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access or call.ast.params.len != 2) continue;
        const data = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(data[1])), "parse")) continue;
        if (try c.role(Contract.library, try c.facts.resolve(c.file, data[0])) != .untrusted) continue;
        const parser = try c.facts.resolve(c.file, call.ast.params[1]);
        if (parser != .function or !selected(c, parser.function.file)) continue;
        try entry(&walk, parser.function, tree.nodeMainToken(node));
    }
}

fn selected(c: *Context, file: @import("Project.zig").FileId) bool {
    return c.project.inputs[file.raw()].selected; // safe: resolved declarations name frozen project files.
}

/// Whether a function declares a parameter of an untrusted type.
fn takesUntrusted(c: *Context, tree: *const Ast, proto: Ast.Node.Index) Context.Error!bool {
    var buffer: [1]Ast.Node.Index = undefined;
    const function = tree.fullFnProto(&buffer, proto) orelse return false;
    var parameters = function.iterate(tree);
    while (parameters.next()) |parameter| {
        const type_expr = parameter.type_expr orelse continue;
        if (try c.role(Contract.library, try c.facts.resolve(c.file, type_expr)) == .untrusted) return true;
    }
    return false;
}

fn entry(self: *Walk, start: Facts.Decl, token: Ast.TokenIndex) Context.Error!void {
    self.unresolved = 0;
    self.done.clearRetainingCapacity();
    try visit(self, start, token);
    if (self.unresolved != 0) {
        const tree = try self.c.project.syntax(try self.c.source());
        try self.c.undecided(self.rule, tree.tokenStart(token), .unresolved, try self.c.allocator.print("{d} calls reachable from untrusted input do not resolve; recursion through them is undecided", .{self.unresolved}));
    }
}

fn visit(self: *Walk, function: Facts.Decl, token: Ast.TokenIndex) Context.Error!void {
    if (self.done.contains(function)) return;
    try self.stack.append(self.c.allocator, function);
    defer _ = self.stack.pop();
    const tree = &self.c.project.files[function.file.raw()].tree; // safe: resolved declarations name frozen project files.
    for (try callsOf(self, function)) |call_node| {
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, call_node).?;
        const callee = try self.c.facts.resolve(function.file, call.ast.fn_expr);
        if (callee != .function) {
            if (callee == .unknown) self.unresolved += 1;
            continue;
        }
        if (!selected(self.c, callee.function.file)) continue;
        try self.edges.append(self.c.allocator, .{ .at = function, .call = call_node });
        defer _ = self.edges.pop();
        const back = for (self.stack.items, 0..) |on, i| {
            if (std.meta.eql(on, callee.function)) break i;
        } else null;
        if (back) |i| try cycle(self, i, token) else try visit(self, callee.function, token);
    }
    try self.done.put(self.c.allocator, function, {});
}

/// The cycle from `stack[from]` back to it through the current edges.
fn cycle(self: *Walk, from: usize, token: Ast.TokenIndex) Context.Error!void {
    const head = self.stack.items[from];
    if (self.reported.contains(head)) return;
    const edges = self.edges.items[self.edges.items.len - (self.stack.items.len - from) ..];
    for (edges) |edge| if (try bounds(self, edge)) return;
    try self.reported.put(self.c.allocator, head, {});
    var names: std.ArrayList(u8) = .empty;
    for (self.stack.items[from..]) |f| {
        try names.appendSlice(self.c.allocator, name(self, f));
        try names.appendSlice(self.c.allocator, " -> ");
    }
    try names.appendSlice(self.c.allocator, name(self, head));
    var related: std.ArrayList(Report.Span) = .empty;
    for (edges) |edge| try related.append(self.c.allocator, try span(self, edge.at.file, edge.call));
    const message = try self.c.allocator.print("recursion reachable from untrusted input ({s}) has no depth bound: input nested deep enough overflows the stack", .{names.items});
    const tree = try self.c.project.syntax(try self.c.source());
    const at = tree.tokenStart(token);
    try self.c.emitRelated(self.rule, at, at + @as(u32, @intCast(tree.tokenSlice(token).len)), message, related.items);
}

fn name(self: *Walk, f: Facts.Decl) []const u8 {
    return self.c.project.models[f.file.raw()].declarations[f.index].name; // safe: resolved declarations name frozen project tables.
}

fn span(self: *Walk, file: @import("Project.zig").FileId, node: Ast.Node.Index) Context.Error!Report.Span {
    const source = &self.c.project.files[file.raw()]; // safe: resolved declarations name frozen project files.
    const start = source.tree.tokenStart(source.tree.nodeMainToken(node));
    const line = source.line(start);
    return .{ .file = file, .start = start, .end = start + 1, .line = line + 1, .column = start - source.lines[line] + 1 };
}

/// Whether the function making `edge`'s call changes a depth it compares: a parameter passed
/// on as `p + k` or `p - k`, or a field moved by `+=`/`-=`, itself or in a function it calls.
fn bounds(self: *Walk, edge: Walk.Edge) Context.Error!bool {
    const tree = &self.c.project.files[edge.at.file.raw()].tree; // safe: resolved declarations name frozen project files.
    const model = &self.c.project.models[edge.at.file.raw()]; // safe: resolved declarations name frozen project files.
    const whole = body(tree, model, edge.at) orelse return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, edge.call).?;
    for (call.ast.params) |argument| if (stepped(tree, model, argument)) |parameter| {
        if (compared(tree, model, whole, .{ .parameter = parameter })) return true;
    };
    if (movedField(tree, model, whole)) return true;
    for (try callsOf(self, edge.at)) |other| {
        const inner = tree.fullCall(&buffer, other).?;
        const callee = try self.c.facts.resolve(edge.at.file, inner.ast.fn_expr);
        if (callee != .function or !selected(self.c, callee.function.file)) continue;
        const callee_tree = &self.c.project.files[callee.function.file.raw()].tree; // safe: resolved declarations name frozen project files.
        const callee_model = &self.c.project.models[callee.function.file.raw()]; // safe: resolved declarations name frozen project files.
        const callee_body = body(callee_tree, callee_model, callee.function) orelse continue;
        if (movedField(callee_tree, callee_model, callee_body)) return true;
    }
    return false;
}

fn body(tree: *const Ast, model: *const Model, f: Facts.Decl) ?Ast.Node.Index {
    const proto = model.declarations[f.index].node;
    const parent = model.node_parents[@backingInt(proto)] orelse return null; // safe: the checked AST indexes its own parent table.
    return if (tree.nodeTag(parent) == .fn_decl) parent else null;
}

/// The parameter `argument` passes on one step away: `p + k`, `p - k` and their wrapping and
/// saturating forms, where `p` is a parameter.
fn stepped(tree: *const Ast, model: *const Model, argument: Ast.Node.Index) ?u32 {
    switch (tree.nodeTag(argument)) {
        .add, .sub, .add_wrap, .sub_wrap, .add_sat, .sub_sat => {},
        else => return null,
    }
    const operands = tree.nodeData(argument).node_and_node;
    inline for (operands) |operand| if (parameterOf(tree, model, operand)) |p| return p;
    return null;
}

fn parameterOf(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?u32 {
    if (tree.nodeTag(node) != .identifier) return null;
    const reference = model.reference(node) orelse return null;
    const d = reference.declaration orelse return null;
    return if (model.declarations[d].kind == .parameter) d else null;
}

const Depth = union(enum) { parameter: u32, field: []const u8 };

/// Whether a comparison inside `whole` has the depth as an operand.
fn compared(tree: *const Ast, model: *const Model, whole: Ast.Node.Index, depth: Depth) bool {
    const first = tree.firstToken(whole);
    const last = tree.lastToken(whole);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .less_than, .greater_than, .less_or_equal, .greater_or_equal, .equal_equal, .bang_equal => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const main = tree.nodeMainToken(node);
        if (main < first or main > last) continue;
        const operands = tree.nodeData(node).node_and_node;
        inline for (operands, 0..) |operand, side| {
            const named = switch (depth) {
                .parameter => |p| parameterOf(tree, model, operand) == p,
                .field => |f| tree.nodeTag(operand) == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(operand).node_and_token[1]), f),
            };
            // A position held against the input's length grows with the input: no bound.
            if (named and !length(tree, operands[1 - side])) return true;
        }
    }
    return false;
}

fn length(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(node).node_and_token[1]), "len");
}

/// Whether `whole` moves a field by `+=` or `-=` and compares it.
fn movedField(tree: *const Ast, model: *const Model, whole: Ast.Node.Index) bool {
    const first = tree.firstToken(whole);
    const last = tree.lastToken(whole);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .assign_add, .assign_sub, .assign_add_wrap, .assign_sub_wrap, .assign_add_sat, .assign_sub_sat => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const main = tree.nodeMainToken(node);
        if (main < first or main > last) continue;
        const target = tree.nodeData(node).node_and_node[0];
        if (tree.nodeTag(target) != .field_access) continue;
        if (compared(tree, model, whole, .{ .field = tree.tokenSlice(tree.nodeData(target).node_and_token[1]) })) return true;
    }
    return false;
}

/// The calls whose nearest enclosing function is `f`, indexed once per file.
fn callsOf(self: *Walk, f: Facts.Decl) Context.Error![]const Ast.Node.Index {
    const tree = &self.c.project.files[f.file.raw()].tree; // safe: resolved declarations name frozen project files.
    const model = &self.c.project.models[f.file.raw()]; // safe: resolved declarations name frozen project files.
    const whole = body(tree, model, f) orelse return &.{};
    const entry_ = try self.calls.getOrPut(self.c.allocator, f.file.raw());
    if (!entry_.found_existing) {
        entry_.value_ptr.* = .empty;
        for (tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            var buffer: [1]Ast.Node.Index = undefined;
            _ = tree.fullCall(&buffer, node) orelse continue;
            var at = model.node_parents[i];
            while (at) |parent| : (at = model.node_parents[@backingInt(parent)]) { // safe: the checked AST indexes its own parent table.
                if (tree.nodeTag(parent) != .fn_decl) continue;
                const list = try entry_.value_ptr.getOrPut(self.c.allocator, @backingInt(parent)); // safe: AST node indexes key their own table.
                if (!list.found_existing) list.value_ptr.* = .empty;
                try list.value_ptr.append(self.c.allocator, node);
                break;
            }
        }
    }
    return if (entry_.value_ptr.get(@backingInt(whole))) |list| list.items else &.{}; // safe: AST node indexes key their own table.
}
