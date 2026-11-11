//! Hygiene: arithmetic done at a narrow width and only then widened, so it overflows before the
//! wide type is reached: `@as(u64, a * b)`, `@as(u64, a << n)`, `const x: u64 = a * b;` where `a`
//! and `b` are names whose declarations write integer types narrower than the destination. Zig
//! computes `a * b` at the operands' peer type: a safe build panics on the overflow, a fast one
//! wraps, and `<<` drops the high bits in every build. Widen an operand first
//! (`@as(u64, a) * b`).
//! Read: `*` and `<<` (the operations whose result outgrows their operands the most); the
//! destination's type and each operand's type as written, `uN` / `iN` only (a `usize` is as wide
//! as the target makes it); an integer literal operand, which takes the other's type. An operand
//! whose type is not written leaves the site unread.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Facts = @import("Facts.zig");
const Written = @import("Written.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        // The destination's written type and the value it is given.
        const destination: Ast.Node.Index, const value: Ast.Node.Index = switch (tag) {
            .builtin_call_two, .builtin_call_two_comma => blk: {
                if (!Facts.isBuiltin(tree, node, "@as")) continue;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, node, &buffer);
                if (args.len != 2) continue;
                break :blk .{ args[0], args[1] };
            },
            .simple_var_decl, .local_var_decl, .global_var_decl, .aligned_var_decl => blk: {
                const declared = tree.fullVarDecl(node) orelse continue;
                break :blk .{ declared.ast.type_node.unwrap() orelse continue, declared.ast.init_node.unwrap() orelse continue };
            },
            else => continue,
        };
        const wide = switch (Written.primitive(tree, destination) orelse continue) {
            .sized => |sized| sized.bits,
            else => continue,
        };
        const operation = Written.ungrouped(tree, value);
        switch (tree.nodeTag(operation)) {
            .mul, .shl => {},
            else => continue,
        }
        const lhs, const rhs = tree.nodeData(operation).node_and_node;
        const narrow = if (tree.nodeTag(operation) == .shl)
            narrowWidth(tree, model, lhs, false)
        else
            joined(narrowWidth(tree, model, lhs, true), narrowWidth(tree, model, rhs, true));
        const bits = switch (narrow orelse continue) {
            .bits => |known| known,
            .literal => continue,
        };
        if (bits >= wide) continue;
        try c.at(rule, tree.nodeMainToken(operation), try c.allocator.print("`{s}` is computed at {d} bits and widened to {d} only after: it overflows first; widen an operand before the operation", .{ tree.tokenSlice(tree.nodeMainToken(operation)), bits, wide }));
    }
}

/// What an operand says of the operation's width: its written `uN`/`iN` width; `literal` (it takes
/// the other's) where `literal_ok` and it is an integer literal; null where it says nothing known.
const Width = union(enum) { bits: u16, literal };

fn narrowWidth(tree: *const Ast, model: *const @import("Model.zig"), operand: Ast.Node.Index, literal_ok: bool) ?Width {
    if (literal_ok and Written.literalInteger(tree, operand) != null) return .literal;
    const written = Written.typeOf(tree, model, operand) orelse return null;
    return switch (Written.primitive(tree, written) orelse return null) {
        .sized => |sized| .{ .bits = sized.bits },
        else => null,
    };
}

/// The width two operands make: the wider of two written widths; a written one beside a literal;
/// none where either says nothing, or both are literals (comptime arithmetic, checked as it
/// compiles).
fn joined(a: ?Width, b: ?Width) ?Width {
    const x = a orelse return null;
    const y = b orelse return null;
    return switch (x) {
        .literal => switch (y) {
            .literal => null,
            .bits => y,
        },
        .bits => |m| switch (y) {
            .literal => x,
            .bits => |n| .{ .bits = @max(m, n) },
        },
    };
}

const breadth = @import("breadth.zig");

test "breadth: narrow widened: a product and a shift widened after, reported; widened first or as wide, not" {
    try breadth.expectFindings(check, "pub fn f(a: u32, b: u32) u64 { return @as(u64, a * b); }", 1);
    try breadth.expectFindings(check, "pub fn f(a: u32) u64 { return @as(u64, a * 1000); }", 1);
    try breadth.expectFindings(check, "pub fn f(a: u32, n: u5) u64 { return @as(u64, a << n); }", 1);
    try breadth.expectFindings(check, "pub fn f(a: u16, b: u16) u64 { const x: u64 = a * b; return x; }", 1);
    try breadth.expectFindings(check, "pub fn f(a: u32, b: u32) u64 { return @as(u64, a) * b; }", 0);
    try breadth.expectFindings(check, "pub fn f(a: u64, b: u32) u64 { return @as(u64, a * b); }", 0);
    try breadth.expectFindings(check, "pub fn f(a: u32, b: u32) u32 { return @as(u32, a * b); }", 0);
    // A width the target decides, or a type not written, is not read.
    try breadth.expectFindings(check, "pub fn f(a: usize, b: usize) u64 { return @as(u64, a * b); }", 0);
    try breadth.expectFindings(check, "pub fn f(a: anytype, b: u32) u64 { return @as(u64, a * b); }", 0);
    try breadth.expectFindings(check, "pub fn f(a: u32, b: u32) u64 { return @as(u64, a + b); }", 0);
}
