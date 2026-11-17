//! Correctness: a compound assignment whose right side calls a function handed the place it
//! updates. Zig loads the left side before it evaluates the right, so what the call writes there
//! is lost: `at.* += (try f(bytes, at)).bytes` adds to the `at.*` from before `f` ran.
//! The left side is read when it is a name followed by field accesses, dereferences and indexes
//! whose index runs no code (`x`, `x.f`, `p.*`, `p.f`, `a[i].f`). A call anywhere on the right is
//! handed the place when one of its arguments is:
//! - `&q`, for `q` the left side or a place it is written through (`x += f(&x)`,
//!   `x.a.b += f(&x.a)`);
//! - a pointer the left side dereferences (`p.* += f(p)`, `p.*.f += f(p)`);
//! - the name the left side starts with, where that name's declaration writes a pointer type and
//!   the left side reaches through it (`p: *S` and `p.n += f(p)`, `s: []u32` and
//!   `s[i] += f(s)`).
//! A ban: a call handed the place is reported whether or not it writes there. An alias the
//! syntax does not show (a pointer copied into another name, one held in a field, a method's
//! receiver) is not read.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Written = @import("Written.zig");
const Model = @import("Model.zig");

/// The most steps a left side is read through; a longer one is not read.
const max_steps = 16;

/// A left side: the places it is written through, itself first and its name last, and the
/// pointers it dereferences.
const Place = struct {
    steps: [max_steps]Ast.Node.Index = undefined,
    step_count: usize = 0,
    derefs: [max_steps]Ast.Node.Index = undefined,
    deref_count: usize = 0,

    fn root(p: *const Place) Ast.Node.Index {
        return p.steps[p.step_count - 1];
    }
};

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const tags = tree.nodes.items(.tag);
    var calls: std.ArrayList(Ast.Node.Index) = .empty;
    defer calls.deinit(c.allocator);
    for (tags, 0..) |tag, i| switch (tag) {
        .call_one, .call_one_comma, .call, .call_comma => try calls.append(c.allocator, @fromBackingInt(@intCast(i))),
        else => {},
    };
    for (tags, 0..) |tag, i| {
        if (!compound(tag)) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const target, const value = tree.nodeData(node).node_and_node;
        const place = read(tree, target) orelse continue;
        const first = tree.firstToken(value);
        const last = tree.lastToken(value);
        for (calls.items) |call_node| {
            if (tree.firstToken(call_node) < first or tree.lastToken(call_node) > last) continue;
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, call_node) orelse continue;
            const handed = for (call.ast.params) |argument| {
                if (hands(tree, model, &place, argument)) break argument;
            } else continue;
            try c.at(rule, tree.nodeMainToken(node), try c.allocator.print(
                "`{s}` is loaded before the call on the right runs, and the call is handed `{s}`: what it writes there is lost; name the call's result in a statement before",
                .{ tree.getNodeSource(target), tree.getNodeSource(handed) },
            ));
            break;
        }
    }
}

fn compound(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .assign_mul, .assign_div, .assign_mod, .assign_add, .assign_sub, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_xor, .assign_bit_or, .assign_mul_wrap, .assign_add_wrap, .assign_sub_wrap, .assign_mul_sat, .assign_add_sat, .assign_sub_sat => true,
        else => false,
    };
}

/// The left side's steps, or null where it is not a name followed by field accesses,
/// dereferences and indexes that run no code.
fn read(tree: *const Ast, target: Ast.Node.Index) ?Place {
    var place: Place = .{};
    var at = Written.ungrouped(tree, target);
    while (true) {
        if (place.step_count == max_steps) return null;
        place.steps[place.step_count] = at;
        place.step_count += 1;
        switch (tree.nodeTag(at)) {
            .identifier => return place,
            .field_access => at = tree.nodeData(at).node_and_token[0],
            .deref => {
                at = tree.nodeData(at).node;
                place.derefs[place.deref_count] = at;
                place.deref_count += 1;
            },
            .array_access => {
                const indexed, const index = tree.nodeData(at).node_and_node;
                if (Written.mayRun(tree, index)) return null;
                at = indexed;
            },
            else => return null,
        }
        at = Written.ungrouped(tree, at);
    }
}

/// Whether `argument` hands a call the place `place` names, in one of the forms the file's
/// comment lists.
fn hands(tree: *const Ast, model: *const Model, place: *const Place, argument: Ast.Node.Index) bool {
    const handed = Written.ungrouped(tree, argument);
    if (tree.nodeTag(handed) == .address_of) {
        const operand = Written.ungrouped(tree, tree.nodeData(handed).node);
        for (place.steps[0..place.step_count]) |step| {
            if (Written.sameTokens(tree, operand, step)) return true;
        }
        return false;
    }
    for (place.derefs[0..place.deref_count]) |pointer| {
        if (Written.sameTokens(tree, handed, pointer)) return true;
    }
    if (place.step_count < 2 or tree.nodeTag(handed) != .identifier) return false;
    if (!Written.sameTokens(tree, handed, place.root())) return false;
    const written = Written.typeOf(tree, model, place.root()) orelse return false;
    return tree.fullPtrType(written) != null;
}

const breadth = @import("breadth_test.zig");

test "breadth: lost update: a call on the right handed the place the left side updates" {
    // The form packages met: a pointer the left side dereferences, handed to the call.
    try breadth.expectFindings(check, "fn f(b: []const u8, at: *usize) usize { at.* += 1; return b.len; } pub fn g(b: []const u8, at: *usize) void { at.* += f(b, at); }", 1);
    try breadth.expectFindings(check, "const R = struct { bytes: usize }; fn f(at: *usize) !R { at.* += 1; return .{ .bytes = 2 }; } pub fn g(at: *usize) !void { at.* += (try f(at)).bytes; }", 1);
    // The address of the left side, or of a place it is written through.
    try breadth.expectFindings(check, "fn f(x: *u32) u32 { x.* = 0; return 1; } pub fn g() u32 { var x: u32 = 1; x += f(&x); return x; }", 1);
    try breadth.expectFindings(check, "const S = struct { a: struct { b: u32 } }; fn f(a: anytype) u32 { _ = a; return 1; } pub fn g(s: *S) void { var x: S = s.*; x.a.b -= f(&x.a); s.* = x; }", 1);
    // A field reached through a pointer the name's declaration writes, or an index into a slice.
    try breadth.expectFindings(check, "const S = struct { n: u32 }; fn f(s: *S) u32 { s.n = 0; return 1; } pub fn g(s: *S) void { s.n += f(s); }", 1);
    try breadth.expectFindings(check, "fn f(s: []u32) u32 { s[0] = 0; return 1; } pub fn g(s: []u32) void { s[0] |= f(s); }", 1);
    try breadth.expectFindings(check, "const S = struct { n: u32 }; fn f(p: *S) u32 { _ = p; return 1; } pub fn g(p: *S) void { p.*.n *= f(p); }", 1);
}

test "breadth: lost update: what the syntax does not show is not read" {
    // The call is handed something else, or a copy.
    try breadth.expectFindings(check, "fn f(b: []const u8, at: usize) usize { return b.len + at; } pub fn g(b: []const u8, at: *usize) void { at.* += f(b, at.*); }", 0);
    try breadth.expectFindings(check, "const S = struct { n: u32 }; fn f(s: S) u32 { return s.n; } pub fn g() void { var s: S = .{ .n = 1 }; s.n += f(s); _ = &s; }", 0);
    try breadth.expectFindings(check, "fn f(a: [2]u32) u32 { return a[0]; } pub fn g() void { var a: [2]u32 = .{ 1, 2 }; a[0] += f(a); _ = &a; }", 0);
    // The call's result named first: the load comes after it.
    try breadth.expectFindings(check, "fn f(at: *usize) usize { at.* += 1; return 1; } pub fn g(at: *usize) void { const n = f(at); at.* += n; }", 0);
    // A pointer whose type is not written, a method's receiver, and a plain assignment.
    try breadth.expectFindings(check, "fn f(p: *u32) u32 { p.* = 0; return 1; } pub fn g(x: *u32) void { const q = x; q.* += f(x); }", 0);
    try breadth.expectFindings(check, "const S = struct { n: u32, fn f(s: *S) u32 { s.n = 0; return 1; } }; pub fn g(s: *S) void { s.n += s.f(); }", 0);
    try breadth.expectFindings(check, "fn f(at: *usize) usize { at.* += 1; return 1; } pub fn g(at: *usize) void { at.* = at.* + f(at); }", 0);
    // An index that runs code is not read.
    try breadth.expectFindings(check, "fn i() usize { return 0; } fn f(s: []u32) u32 { _ = s; return 1; } pub fn g(s: []u32) void { s[i()] += f(s); }", 0);
}
