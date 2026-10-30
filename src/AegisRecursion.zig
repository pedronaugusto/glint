//! A006: recursion reachable from untrusted input without a depth bound. Input an attacker
//! shapes can nest as deep as it likes, and each level of a recursive parser takes stack: the
//! program overflows it instead of refusing the input.
//!
//! Untrusted input is aegis's `input.Untrusted`: a function of the program that takes one as a
//! parameter, or that a program passes to an untrusted value's `parse` as its parser, is an
//! entry. From each entry the walk follows calls that resolve to the program's own functions
//! (std and aegis aside). A call cycle it reaches is bounded when one function on it steps a
//! depth on its call and holds it there: a parameter it passes on as `p + k` or `p - k`, or a
//! field it moves with `+=` or `-=` before the call, itself or in a callee it `try`s before the
//! call (`k` a literal above zero), and a comparison that leaves before the call keeps the depth
//! at most a bound where it grows, at least one where it shrinks. The bound is one the input
//! does not choose (Taint reads it clean: a length of the input is no bound), and so is the
//! start of a shrinking parameter.
//! A function that returns a type, or takes only comptime parameters, recurses over the types
//! it is given, not over input, and the walk does not enter it.
//! A bound kept further away, such as in an aegis `Budget`, is not seen, so the site is
//! reported and a written suppression names it. A call whose callee is no declared function (one
//! that does not resolve, a function pointer, a vtable's field) leaves what it reaches
//! undecided; the walk records how many such calls an entry reaches.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Contract = @import("AegisContract.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Range = @import("Range.zig");
const Taint = @import("Taint.zig");
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
    /// The calls on the walk from the current entry that do not resolve, named for the report.
    unresolved: std.ArrayList(Unresolved) = .empty,
    reported: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty,

    const Edge = struct { at: Facts.Decl, call: Ast.Node.Index };
    const Unresolved = struct { file: @import("Project.zig").FileId, call: Ast.Node.Index };
};

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = try c.project.syntax(try c.source());
    const model = &c.project.at(c.file).model;
    var walk: Walk = .{ .c = c, .rule = rule };
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .function) continue;
        if (!try takesUntrusted(c, tree, decl.node)) continue;
        try entry(&walk, .{ .file = c.file, .index = @fromBackingInt(@intCast(d)) }, decl.token);
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
    return c.project.at(file).input.selected;
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
    self.unresolved.clearRetainingCapacity();
    self.done.clearRetainingCapacity();
    try visit(self, start, token);
    if (self.unresolved.items.len != 0) {
        const tree = try self.c.project.syntax(try self.c.source());
        // Each by its place and spelling: an unresolved call is settled by giving it a type.
        var names: std.Io.Writer.Allocating = .init(self.c.allocator);
        for (self.unresolved.items, 0..) |one, i| {
            const file = &self.c.project.at(one.file).file;
            const at = file.line(file.tree.tokenStart(file.tree.firstToken(one.call))) + 1;
            var buffer: [1]Ast.Node.Index = undefined;
            const callee = file.tree.getNodeSource(file.tree.fullCall(&buffer, one.call).?.ast.fn_expr);
            // An allocating writer fails only when its allocation does.
            names.writer.print("{s}{s}:{d} `{s}`", .{ if (i == 0) "" else ", ", self.c.project.at(one.file).input.name, at, callee }) catch return error.OutOfMemory;
        }
        try self.c.undecided(self.rule, tree.tokenStart(token), .unresolved, try self.c.allocator.print("{d} calls reachable from untrusted input do not resolve ({s}); recursion through them is undecided", .{ self.unresolved.items.len, names.written() }));
    }
}

fn visit(self: *Walk, function: Facts.Decl, token: Ast.TokenIndex) Context.Error!void {
    if (self.done.contains(function)) return;
    try self.stack.append(self.c.allocator, function);
    defer _ = self.stack.pop();
    const tree = &self.c.project.at(function.file).file.tree;
    for (try callsOf(self, function)) |call_node| {
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, call_node).?;
        // A call reaches a function, or one of several a branch chose; through anything else (a
        // function pointer, a vtable's field, what does not resolve) where it goes is undecided.
        const callee = try self.c.facts.resolve(function.file, call.ast.fn_expr);
        const one = [1]Facts.Value{callee};
        const choices: []const Facts.Value = if (callee == .alternatives) callee.alternatives else &one;
        for (choices) |choice| if (choice != .function) {
            try self.unresolved.append(self.c.allocator, .{ .file = function.file, .call = call_node });
            break;
        };
        for (choices) |choice| {
            if (choice != .function) continue;
            if (!selected(self.c, choice.function.file) or compileTime(self, choice.function)) continue;
            try self.edges.append(self.c.allocator, .{ .at = function, .call = call_node });
            defer _ = self.edges.pop();
            for (self.stack.items, 0..) |on, i| {
                if (!std.meta.eql(on, choice.function)) continue;
                // The calls from the stack's functions are the edges, one each.
                if (i <= self.edges.items.len) try cycle(self, self.stack.items[i..], self.edges.items[i..], token);
                break;
            } else try visit(self, choice.function, token);
        }
    }
    try self.done.put(self.c.allocator, function, {});
}

/// Whether a function's recursion is fixed by the program, not by input: it returns a type, so
/// it runs only at compile time, or every parameter it takes is comptime (`comptime T: type`,
/// `comptime seen: []const type`), so no value read at run time reaches it and its depth is the
/// types' it is given (strand's descriptors).
fn compileTime(self: *Walk, f: Facts.Decl) bool {
    const tree = &self.c.project.at(f.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, self.c.project.at(f.file).model.declarations[@backingInt(f.index)].node) orelse return false;
    if (proto.ast.return_type.unwrap()) |result| if (typeKeyword(tree, result)) return true;
    var parameters = proto.iterate(tree);
    var any = false;
    while (parameters.next()) |parameter| {
        any = true;
        const declared = if (parameter.comptime_noalias) |token| tree.tokenTag(token) == .keyword_comptime else false;
        const typed = if (parameter.type_expr) |expr| typeKeyword(tree, expr) else false;
        if (!declared and !typed) return false;
    }
    return any;
}

/// Whether a type expression is the type `type`.
fn typeKeyword(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "type");
}

/// The cycle `looped` (the stack from the function called again) makes back to its first
/// function through `edges`, each one's call.
fn cycle(self: *Walk, looped: []const Facts.Decl, edges: []const Walk.Edge, token: Ast.TokenIndex) Context.Error!void {
    if (looped.len == 0) return;
    const head = looped[0];
    if (self.reported.contains(head)) return;
    for (edges) |edge| if (try bounds(self, edge)) return;
    try self.reported.put(self.c.allocator, head, {});
    var names: std.ArrayList(u8) = .empty;
    for (looped) |f| {
        try names.appendSlice(self.c.allocator, name(self, f));
        try names.appendSlice(self.c.allocator, " -> ");
    }
    try names.appendSlice(self.c.allocator, name(self, head));
    var related: std.ArrayList(Report.Span) = .empty;
    for (edges) |edge| try related.append(self.c.allocator, self.c.spanOf(edge.at.file, self.c.project.at(edge.at.file).file.tree.nodeMainToken(edge.call)));
    const message = try self.c.allocator.print("recursion reachable from untrusted input ({s}) has no depth bound: input nested deep enough overflows the stack", .{names.items});
    const tree = try self.c.project.syntax(try self.c.source());
    const at = tree.tokenToSpan(token);
    try self.c.emitRelated(self.rule, at.start, at.end, message, related.items);
}

fn name(self: *Walk, f: Facts.Decl) []const u8 {
    return self.c.project.at(f.file).model.declarations[@backingInt(f.index)].name;
}

/// Whether the function making `edge`'s call bounds the depth there. The depth steps toward an
/// end on each call: a parameter passed on as `p + k` or `p - k` (`k` a literal above zero, in
/// any of their wrapping and saturating forms), or a field moved by `+=` or `-=` by such a `k`
/// before the call, in the function itself or in a callee it `try`s before the call. And a
/// comparison that leaves before the call holds the depth to a bound the input does not
/// choose (Taint reads it clean), in the way it steps: at most the bound where it grows, at
/// least it where it shrinks. A shrinking parameter starts where it is given, so the input must
/// not choose that either. A step kept in a `defer` runs after the call, and moves nothing first.
fn bounds(self: *Walk, edge: Walk.Edge) Context.Error!bool {
    const c = self.c;
    const file = edge.at.file;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const flow = try Taint.get(c, .input);
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, edge.call).?; // unreachable: an edge is a call
    for (call.ast.params) |argument| if (stepped(tree, model, argument)) |step| {
        const side: Range.Side = if (step.grows) .ceiling else .floor;
        if (!step.grows and try Taint.levelAt(c, flow, file, step.depth) != .clean) continue;
        if (try held(c, flow, file, step.depth, step.depth, side)) return true;
    };
    // A field the function moves before the call, held by a guard before the move or between
    // it and the call.
    for (try movesBefore(self, file, edge.call)) |move| {
        const side: Range.Side = if (move.grows) .ceiling else .floor;
        if (try held(c, flow, file, move.depth, move.depth, side) or try held(c, flow, file, edge.call, move.depth, side)) return true;
    }
    // A callee the function `try`s before the call, which moves a field of its receiver and
    // fails unless a guard holds it: what it checked holds where it succeeded.
    for (try triedBefore(self, file, edge.call)) |callee| {
        for (try movesIn(self, callee)) |move| {
            const side: Range.Side = if (move.grows) .ceiling else .floor;
            if (try held(c, flow, file, edge.call, move.depth, side)) return true;
        }
    }
    return false;
}

/// Whether a comparison holding where `at` is evaluated holds `depth` to a clean bound on `side`.
fn held(c: *Context, flow: *Taint.Flow, file: @import("Project.zig").FileId, at: Ast.Node.Index, depth: Ast.Node.Index, side: Range.Side) Context.Error!bool {
    for (try Range.boundsAt(c, file, at, depth, side)) |bound| if (try Taint.levelAt(c, flow, file, bound) == .clean) return true;
    return false;
}

fn body(tree: *const Ast, model: *const Model, f: Facts.Decl) ?Ast.Node.Index {
    const proto = model.declarations[@backingInt(f.index)].node;
    const parent = model.parentOf(proto) orelse return null;
    return if (tree.nodeTag(parent) == .fn_decl) parent else null;
}

/// A depth one step moves: the expression that names it, and whether the step grows it.
const Step = struct { depth: Ast.Node.Index, grows: bool };

/// The parameter `argument` passes on one step away: `p + k`, `k + p`, `p - k` and their wrapping
/// and saturating forms, where `p` is a parameter and `k` a literal above zero.
fn stepped(tree: *const Ast, model: *const Model, argument: Ast.Node.Index) ?Step {
    const grows = switch (tree.nodeTag(argument)) {
        .add, .add_wrap, .add_sat => true,
        .sub, .sub_wrap, .sub_sat => false,
        else => return null,
    };
    const lhs, const rhs = tree.nodeData(argument).node_and_node;
    if (parameterOf(tree, model, lhs) != null and positive(tree, rhs)) return .{ .depth = lhs, .grows = grows };
    if (grows and parameterOf(tree, model, rhs) != null and positive(tree, lhs)) return .{ .depth = rhs, .grows = grows };
    return null;
}

fn parameterOf(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Model.Declaration.Id {
    if (tree.nodeTag(node) != .identifier) return null;
    const reference = model.reference(node) orelse return null;
    const d = reference.declaration orelse return null;
    return if (model.declarations[@backingInt(d)].kind == .parameter) d else null;
}

/// Whether `node` is an integer literal above zero.
fn positive(tree: *const Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .number_literal) return false;
    return switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
        .int => |n| n > 0,
        .big_int => true,
        else => false,
    };
}

/// The step `node` takes if it moves a field by a literal above zero: `x.f += k`, `x.f -= k` and
/// their wrapping and saturating forms.
fn fieldStep(tree: *const Ast, node: Ast.Node.Index) ?Step {
    const grows = switch (tree.nodeTag(node)) {
        .assign_add, .assign_add_wrap, .assign_add_sat => true,
        .assign_sub, .assign_sub_wrap, .assign_sub_sat => false,
        else => return null,
    };
    const target, const by = tree.nodeData(node).node_and_node;
    if (tree.nodeTag(target) != .field_access or !positive(tree, by)) return null;
    return .{ .depth = target, .grows = grows };
}

/// The statements that run before `call` on every way to it: the earlier statements of each
/// block around it, up to its function.
fn before(self: *Walk, file: @import("Project.zig").FileId, call: Ast.Node.Index) Context.Error![]const Ast.Node.Index {
    const tree = &self.c.project.at(file).file.tree;
    const model = &self.c.project.at(file).model;
    var out: std.ArrayList(Ast.Node.Index) = .empty;
    var at = call;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) break;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, parent) orelse continue;
        for (statements) |statement| {
            if (statement == at) break;
            try out.append(self.c.allocator, statement);
        }
    }
    return out.items;
}

/// The field moves among the statements that run before `call`.
fn movesBefore(self: *Walk, file: @import("Project.zig").FileId, call: Ast.Node.Index) Context.Error![]const Step {
    const tree = &self.c.project.at(file).file.tree;
    var out: std.ArrayList(Step) = .empty;
    for (try before(self, file, call)) |statement| if (fieldStep(tree, statement)) |step| try out.append(self.c.allocator, step);
    return out.items;
}

/// The field moves among a function's own statements.
fn movesIn(self: *Walk, f: Facts.Decl) Context.Error![]const Step {
    const tree = &self.c.project.at(f.file).file.tree;
    const model = &self.c.project.at(f.file).model;
    const whole = body(tree, model, f) orelse return &.{};
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, tree.nodeData(whole).node_and_node[1]) orelse return &.{};
    var out: std.ArrayList(Step) = .empty;
    for (statements) |statement| if (fieldStep(tree, statement)) |step| try out.append(self.c.allocator, step);
    return out.items;
}

/// The program's functions of `call`'s file that a statement before it calls with `try`, alone
/// or as a local's value.
fn triedBefore(self: *Walk, file: @import("Project.zig").FileId, call: Ast.Node.Index) Context.Error![]const Facts.Decl {
    const tree = &self.c.project.at(file).file.tree;
    var out: std.ArrayList(Facts.Decl) = .empty;
    for (try before(self, file, call)) |statement| {
        var tried = statement;
        if (tree.fullVarDecl(statement)) |local| tried = local.ast.init_node.unwrap() orelse continue;
        if (tree.nodeTag(tried) != .@"try") continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const inner = tree.fullCall(&buffer, tree.nodeData(tried).node) orelse continue;
        const callee = try self.c.facts.resolve(file, inner.ast.fn_expr);
        if (callee != .function or callee.function.file != file) continue;
        try out.append(self.c.allocator, callee.function);
    }
    return out.items;
}
/// The calls whose nearest enclosing function is `f`, indexed once per file.
fn callsOf(self: *Walk, f: Facts.Decl) Context.Error![]const Ast.Node.Index {
    const tree = &self.c.project.at(f.file).file.tree;
    const model = &self.c.project.at(f.file).model;
    const whole = body(tree, model, f) orelse return &.{};
    const entry_ = try self.calls.getOrPut(self.c.allocator, @backingInt(f.file));
    if (!entry_.found_existing) {
        entry_.value_ptr.* = .empty;
        for (tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            var buffer: [1]Ast.Node.Index = undefined;
            _ = tree.fullCall(&buffer, node) orelse continue;
            var at = model.node_parents[i];
            while (at) |parent| : (at = model.parentOf(parent)) {
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
