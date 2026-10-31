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
const Program = @import("Program.zig");
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
        if (parser != .function or !try Program.owns(c, parser.function.file)) continue;
        try entry(&walk, parser.function, tree.nodeMainToken(node));
    }
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
            if (!try Program.owns(self.c, choice.function.file) or compileTime(self, choice.function)) continue;
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
    if (try carried(self, looped, edges)) return;
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

/// Where a cycle keeps its depth in each function on it: a parameter by its position, or a
/// field (by its declaration) of what a parameter points at.
const Slot = union(enum) {
    param: usize,
    field: struct { param: usize, decl: Facts.Decl },
};

/// Whether a depth is carried around the cycle `looped` makes through `edges` and bounded on it:
/// each call hands the next function the depth it was given, as it is or one step on, so the
/// cycle comes back to the same depth; every step moves it one way; and a step on at least one
/// call is held to a bound the input does not choose. A field depth is one object's: each call
/// passes that object on, and nothing in the program moves its field the other way (`monotone`).
/// A value only compared, a parameter passed on in another position, a fresh object's field, or
/// a depth the cycle resets bounds nothing.
fn carried(self: *Walk, looped: []const Facts.Decl, edges: []const Walk.Edge) Context.Error!bool {
    const count = parameterCount(self, looped[0]);
    for (0..count) |i| if (try around(self, looped, edges, 0, .{ .param = i }, .{ .param = i }, null, false) != null) return true;
    var fields: std.ArrayList(Facts.Decl) = .empty;
    for (edges) |edge| {
        for (try movesBefore(self, edge.at.file, edge.call)) |move| if (try fieldOf(self.c, edge.at.file, move.depth)) |decl| try fields.append(self.c.allocator, decl);
        for (try triedBefore(self, edge.at.file, edge.call)) |tried| for (try movesIn(self, tried.callee)) |move| if (try fieldOf(self.c, tried.callee.file, move.depth)) |decl| try fields.append(self.c.allocator, decl);
    }
    for (fields.items) |decl| for (0..count) |r| {
        const start: Slot = .{ .field = .{ .param = r, .decl = decl } };
        const grows = try around(self, looped, edges, 0, start, start, null, false) orelse continue;
        if (try monotone(self, decl, grows)) return true;
    };
    return false;
}

/// Following `slot` from the call `edges[at]` on: the way the depth steps where it comes back
/// to `start` with a held step on the way, or null.
fn around(self: *Walk, looped: []const Facts.Decl, edges: []const Walk.Edge, at: usize, start: Slot, slot: Slot, grows: ?bool, guarded: bool) Context.Error!?bool {
    if (at == edges.len) return if (guarded and std.meta.eql(slot, start)) grows else null;
    const c = self.c;
    const edge = edges[at];
    const from = edge.at;
    const file = from.file;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const flow = try Taint.get(c, .input);
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, edge.call).?; // unreachable: an edge is a call
    const receiver = try hasReceiver(c, file, call);
    const positions = @min(call.ast.params.len + @intFromBool(receiver), parameterCount(self, looped[(at + 1) % looped.len]));
    for (0..positions) |position| {
        const argument = plain(tree, argumentAt(tree, call, receiver, position));
        switch (slot) {
            .param => |p| {
                if (parameterPosition(self, from, argument) == p) {
                    if (try around(self, looped, edges, at + 1, start, .{ .param = position }, grows, guarded)) |way| return way;
                    continue;
                }
                const step = stepped(tree, model, argument) orelse continue;
                if (parameterPosition(self, from, step.depth) != p) continue;
                if (grows) |way| if (way != step.grows) continue;
                // A shrinking depth starts where it is given: the input must not choose it.
                const side: Range.Side = if (step.grows) .ceiling else .floor;
                const holds = (step.grows or try Taint.levelAt(c, flow, file, step.depth) == .clean) and try held(c, flow, file, step.depth, step.depth, side);
                if (try around(self, looped, edges, at + 1, start, .{ .param = position }, step.grows, guarded or holds)) |way| return way;
            },
            .field => |f| {
                if (parameterPosition(self, from, argument) != f.param) continue;
                var way = grows;
                var holds = guarded;
                // A field the function moves before the call, held by a guard before the move or
                // between it and the call.
                for (try movesBefore(self, file, edge.call)) |move| {
                    if (!try movesSlot(self, from, file, move, f.param, f.decl)) continue;
                    if (way) |w| if (w != move.grows) continue;
                    way = move.grows;
                    const side: Range.Side = if (move.grows) .ceiling else .floor;
                    if (try held(c, flow, file, move.depth, move.depth, side) or try held(c, flow, file, edge.call, move.depth, side)) holds = true;
                }
                // A callee the function `try`s before the call on the same object, which moves
                // the field of its parameter and fails unless a guard holds it: what it checked
                // holds where it succeeded.
                for (try triedBefore(self, file, edge.call)) |tried| {
                    var tried_buffer: [1]Ast.Node.Index = undefined;
                    const inner = tree.fullCall(&tried_buffer, tried.call).?; // unreachable: tried calls are calls
                    const inner_receiver = try hasReceiver(c, file, inner);
                    for (try movesIn(self, tried.callee)) |move| {
                        const root = plain(tree, tree.nodeData(move.depth).node_and_token[0]);
                        const q = parameterPosition(self, tried.callee, root) orelse continue;
                        if (q >= inner.ast.params.len + @intFromBool(inner_receiver)) continue;
                        if (parameterPosition(self, from, plain(tree, argumentAt(tree, inner, inner_receiver, q))) != f.param) continue;
                        if (!std.meta.eql(try fieldOf(c, file, move.depth), f.decl)) continue;
                        if (way) |w| if (w != move.grows) continue;
                        way = move.grows;
                        const side: Range.Side = if (move.grows) .ceiling else .floor;
                        if (try held(c, flow, file, edge.call, move.depth, side)) holds = true;
                    }
                }
                if (try around(self, looped, edges, at + 1, start, .{ .field = .{ .param = position, .decl = f.decl } }, way, holds)) |w| return w;
            },
        }
    }
    return null;
}

/// Whether `move` steps the field `decl` of what `from`'s parameter at `param` points at.
fn movesSlot(self: *Walk, from: Facts.Decl, file: @import("Project.zig").FileId, move: Step, param: usize, decl: Facts.Decl) Context.Error!bool {
    const tree = &self.c.project.at(file).file.tree;
    if (parameterPosition(self, from, plain(tree, tree.nodeData(move.depth).node_and_token[0])) != param) return false;
    return std.meta.eql(try fieldOf(self.c, file, move.depth), decl);
}

/// Whether nothing in the program moves the field `decl` against `grows`: every store that
/// may reach it steps it that way by a literal (`d.depth += 1`), or is a `defer` undoing at
/// most a step its block took before it on the same object (`p.depth += 1; defer p.depth -= 1;`),
/// which runs once that block's calls are done. Any other store to it, by any name (`@field`,
/// the whole struct, a struct holding it, memory a builtin writes, a function outside the
/// program handed a pointer that reaches it, `asm`) may reset it, and a depth reset is no depth.
fn monotone(self: *Walk, decl: Facts.Decl, grows: bool) Context.Error!bool {
    const c = self.c;
    const program = try Program.get(c);
    for (c.project.sources) |*each| {
        if (each.input.classification == .@"test") continue;
        const file = each.id;
        if (!program.own(file)) continue;
        const tree = &each.file.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            switch (tag) {
                .assign, .assign_add, .assign_add_wrap, .assign_add_sat, .assign_sub, .assign_sub_wrap, .assign_sub_sat, .assign_mul, .assign_mul_wrap, .assign_mul_sat, .assign_div, .assign_mod, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor => if (!try keepsWay(self, file, node, decl, grows)) return false,
                .assign_destructure => for (tree.assignDestructure(node).ast.variables) |target| {
                    if (tree.fullVarDecl(target) != null) continue;
                    if (try reachesStore(c, file, target, decl)) return false;
                },
                .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                    const name_ = tree.tokenSlice(tree.nodeMainToken(node));
                    if (!Range.writesMemory(name_)) continue;
                    var args_buffer: [2]Ast.Node.Index = undefined;
                    for (Facts.builtinArgs(tree, node, &args_buffer)) |arg| if (try reaches(c, file, arg, decl)) return false;
                },
                .asm_simple, .@"asm" => return false,
                .call_one, .call_one_comma, .call, .call_comma => {
                    var call_buffer: [1]Ast.Node.Index = undefined;
                    const call = tree.fullCall(&call_buffer, node).?; // unreachable: the tag is a call's
                    // The program's own functions are read here as they are.
                    const callee = try c.facts.resolve(file, call.ast.fn_expr);
                    if (callee == .function and program.own(callee.function.file)) continue;
                    if (tree.nodeTag(call.ast.fn_expr) == .field_access) if (try reaches(c, file, tree.nodeData(call.ast.fn_expr).node_and_token[0], decl)) return false;
                    for (call.ast.params) |arg| if (try reaches(c, file, arg, decl)) return false;
                },
                else => {},
            }
        }
    }
    return true;
}

/// Whether the store `node` keeps the field `decl` moving only as `grows` says (`monotone`).
fn keepsWay(self: *Walk, file: @import("Project.zig").FileId, node: Ast.Node.Index, decl: Facts.Decl, grows: bool) Context.Error!bool {
    const c = self.c;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const target, const by = tree.nodeData(node).node_and_node;
    const named = try storedField(c, file, target);
    if (!std.meta.eql(named, decl)) return !try reachesStore(c, file, target, decl);
    const step = fieldStep(tree, node) orelse return false;
    if (step.grows == grows) return true;
    // An undo: the whole of a `defer` in a block that stepped the same object at least as far
    // before it.
    const statement = model.parentOf(node) orelse return false;
    if (tree.nodeTag(statement) != .@"defer" or tree.nodeData(statement).node != node) return false;
    const block = model.parentOf(statement) orelse return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block) orelse return false;
    const root = rootDeclaration(c, file, target) orelse return false;
    const undo = literalValue(tree, by) orelse return false;
    for (statements) |earlier| {
        if (earlier == statement) break;
        const forward = fieldStep(tree, earlier) orelse continue;
        if (forward.grows != grows) continue;
        const moved = tree.nodeData(earlier).node_and_node[0];
        if (!std.meta.eql(try storedField(c, file, moved), decl)) continue;
        if (rootDeclaration(c, file, moved) != root) continue;
        if ((literalValue(tree, tree.nodeData(earlier).node_and_node[1]) orelse continue) >= undo) return true;
    }
    return false;
}

/// The field a store's target names by its declaration: `x.f`, or `@field(x, "f")`.
fn storedField(c: *Context, file: @import("Project.zig").FileId, target: Ast.Node.Index) Context.Error!?Facts.Decl {
    const tree = &c.project.at(file).file.tree;
    switch (tree.nodeTag(target)) {
        .field_access => return fieldOf(c, file, target),
        .builtin_call_two, .builtin_call_two_comma => {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "@field")) return null;
            const named = try Taint.namedFields(c, file, target);
            return if (named.len == 1) named[0] else null;
        },
        else => return null,
    }
}

/// The parameter or constant a field store's object is (`p` of `p.depth`), which names one
/// object wherever it is read; null for any other.
fn rootDeclaration(c: *Context, file: @import("Project.zig").FileId, target: Ast.Node.Index) ?Model.Declaration.Id {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const holder = switch (tree.nodeTag(target)) {
        .field_access => tree.nodeData(target).node_and_token[0],
        else => blk: {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, target, &buffer);
            if (args.len != 2) return null;
            break :blk args[0];
        },
    };
    const at = plain(tree, holder);
    if (tree.nodeTag(at) != .identifier) return null;
    const d = (model.reference(at) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(d)];
    if (record.kind == .parameter) return d;
    if (record.kind != .variable) return null;
    const local = tree.fullVarDecl(record.node) orelse return null;
    return if (tree.tokenTag(local.ast.mut_token) == .keyword_const) d else null;
}

/// Whether a store to `target` may write the field `decl`: its memory holds the field by value
/// (the struct, a struct or array holding it), or its type does not resolve. A local by its own
/// name is the function's, and a pointer stored is no pointee written.
fn reachesStore(c: *Context, file: @import("Project.zig").FileId, target: Ast.Node.Index, decl: Facts.Decl) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    if (tree.nodeTag(target) == .identifier) {
        if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) return false;
        const d = (model.reference(target) orelse return true).declaration orelse return true;
        const record = model.declarations[@backingInt(d)];
        if (record.kind == .parameter or record.kind == .capture) return false;
        const scope = model.scopes[@backingInt(record.scope)].kind;
        if (scope != .container and scope != .file) return false;
    }
    return byValue(c, try c.facts.resolve(file, target), decl, 0);
}

/// Whether a value's own memory holds the field `decl`: it is an instance of a container that
/// declares it, or holds one by value in a field or element; true where the type does not
/// resolve.
fn byValue(c: *Context, value: Facts.Value, decl: Facts.Decl, depth: u8) Context.Error!bool {
    if (depth >= 16) return true;
    switch (value) {
        .instance => |k| {
            for (try Taint.fieldsOf(c, k)) |field| {
                if (std.meta.eql(field, decl)) return true;
                if (try byValue(c, try c.facts.declaration(field), decl, depth + 1)) return true;
            }
            return false;
        },
        .array, .optional, .error_union => |inner| return byValue(c, inner.*, decl, depth + 1),
        .alternatives => |each| {
            for (each) |one| if (try byValue(c, one, decl, depth + 1)) return true;
            return false;
        },
        .unknown, .reified, .literal => return true,
        else => return false,
    }
}

/// Whether memory `node` reaches, by value or through pointers, may hold the field `decl`.
fn reaches(c: *Context, file: @import("Project.zig").FileId, node: Ast.Node.Index, decl: Facts.Decl) Context.Error!bool {
    const fields = try Taint.wholeFields(c, try c.facts.resolve(file, node)) orelse return true;
    for (fields) |field| if (std.meta.eql(field, decl)) return true;
    return false;
}

/// The field `x.f` names by its declaration, where `x`'s type resolves.
fn fieldOf(c: *Context, file: @import("Project.zig").FileId, node: Ast.Node.Index) Context.Error!?Facts.Decl {
    const tree = &c.project.at(file).file.tree;
    if (tree.nodeTag(node) != .field_access) return null;
    const holder, const name_token = tree.nodeData(node).node_and_token;
    var value = try c.facts.resolve(file, holder);
    while (true) value = switch (value) {
        .pointer, .optional => |inner| inner.*,
        else => break,
    };
    const container = switch (value) {
        .instance => |k| k,
        else => return null,
    };
    const decl = c.facts.member(container, try Model.identifier(c.allocator, tree.tokenSlice(name_token))) orelse return null;
    if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind != .field) return null;
    return decl;
}

/// Whether a call hands its callee a receiver as the first parameter: `x.f(…)` on a value.
fn hasReceiver(c: *Context, file: @import("Project.zig").FileId, call: Ast.full.Call) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    return switch (try c.facts.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
        .instance, .pointer, .optional => true,
        else => false,
    };
}

/// What a call gives its callee's parameter at `position`.
fn argumentAt(tree: *const Ast, call: Ast.full.Call, receiver: bool, position: usize) Ast.Node.Index {
    if (receiver) return if (position == 0) tree.nodeData(call.ast.fn_expr).node_and_token[0] else call.ast.params[position - 1];
    return call.ast.params[position];
}

/// An expression past what keeps its value: parentheses, `@as` and `@intCast`.
fn plain(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = node;
    while (true) switch (tree.nodeTag(at)) {
        .grouped_expression => at = tree.nodeData(at).node_and_token[0],
        .builtin_call_two, .builtin_call_two_comma => {
            const name_ = tree.tokenSlice(tree.nodeMainToken(at));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, at, &buffer);
            if (std.mem.eql(u8, name_, "@as") and args.len == 2) {
                at = args[1];
            } else if (std.mem.eql(u8, name_, "@intCast") and args.len == 1) {
                at = args[0];
            } else return at;
        },
        else => return at,
    };
}

/// The position among `f`'s parameters of the one `node` names, if it names one.
fn parameterPosition(self: *Walk, f: Facts.Decl, node: Ast.Node.Index) ?usize {
    const model = &self.c.project.at(f.file).model;
    const tree = &self.c.project.at(f.file).file.tree;
    const d = parameterOf(tree, model, node) orelse return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(f.index)].node) orelse return null;
    var parameters = proto.iterate(tree);
    var position: usize = 0;
    while (parameters.next()) |parameter| : (position += 1) {
        if (parameter.name_token == model.declarations[@backingInt(d)].token) return position;
    }
    return null;
}

fn parameterCount(self: *Walk, f: Facts.Decl) usize {
    const tree = &self.c.project.at(f.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, self.c.project.at(f.file).model.declarations[@backingInt(f.index)].node) orelse return 0;
    var parameters = proto.iterate(tree);
    var count: usize = 0;
    while (parameters.next()) |_| count += 1;
    return count;
}

/// An integer literal's value.
fn literalValue(tree: *const Ast, node: Ast.Node.Index) ?u64 {
    if (tree.nodeTag(node) != .number_literal) return null;
    return switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
        .int => |n| n,
        else => null,
    };
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

/// A call a statement before another `try`s, and the function it reaches.
const Tried = struct { callee: Facts.Decl, call: Ast.Node.Index };

/// The program's functions of `call`'s file that a statement before it calls with `try`, alone
/// or as a local's value.
fn triedBefore(self: *Walk, file: @import("Project.zig").FileId, call: Ast.Node.Index) Context.Error![]const Tried {
    const tree = &self.c.project.at(file).file.tree;
    var out: std.ArrayList(Tried) = .empty;
    for (try before(self, file, call)) |statement| {
        var tried = statement;
        if (tree.fullVarDecl(statement)) |local| tried = local.ast.init_node.unwrap() orelse continue;
        if (tree.nodeTag(tried) != .@"try") continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const inner = tree.fullCall(&buffer, tree.nodeData(tried).node) orelse continue;
        const callee = try self.c.facts.resolve(file, inner.ast.fn_expr);
        if (callee != .function or callee.function.file != file) continue;
        try out.append(self.c.allocator, .{ .callee = callee.function, .call = tree.nodeData(tried).node });
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
