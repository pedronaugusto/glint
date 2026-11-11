//! Hygiene: `std.testing.expect(a == b)`, where `expectEqual` says the same and prints
//! both values when it fails; `expect` prints nothing. Read: a call whose every callee is std's
//! `testing.expect` (`Governed.stdCall`, through aliases), its argument written `==`
//! through parentheses, with a side written as a value literal: a number, a character, a string,
//! `null`, `true` or `false`. Such a side makes the other a type `expectEqual` compares as `==`
//! does. An enum literal does not: `u == .tag` reads a tagged union's tag, where
//! `expectEqual(.tag, u)` would make `.tag` a union and does not compile when its payload is not
//! void; with no literal side either may be such a union. Those, `!=` and other comparisons are
//! left. Its fix (`rewrite`) writes `expectEqual(literal, other)` where exactly one side is a
//! literal. A callee that does not resolve is silent.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Report = @import("Report.zig");
const Rule = @import("Rule.zig").Rule;
const Facts = @import("Facts.zig");
const Governed = @import("Governed.zig");
const Written = @import("Written.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (try Facts.calls.in(c.facts, c.file)) |call| {
        const args = switch (call.args) {
            .known => |args| args,
            .unknown => continue,
        };
        const written = if (call.receiver == .bound) args[@min(args.len, 1)..] else args;
        if (written.len != 1) continue;
        const operator = tree.nodeTag(Written.ungrouped(tree, written[0]));
        if (operator != .equal_equal) continue;
        const lhs, const rhs = tree.nodeData(Written.ungrouped(tree, written[0])).node_and_node;
        if (!literal(tree, lhs) and !literal(tree, rhs)) continue;
        if (try Governed.stdCall(c, call.node, "testing.expect") != .yes) continue;
        const message = "std.testing.expect of `a == b`: expectEqual(expected, actual) says the same and prints both values when it fails";
        var edits: std.ArrayList(Report.Edit) = .empty;
        if (try rewrite(c, tree, call.callee_expr, Written.ungrouped(tree, written[0]), &edits))
            try c.fixedAt(rule, tree.nodeMainToken(call.node), message, edits.items)
        else
            try c.at(rule, tree.nodeMainToken(call.node), message);
    }
}

/// The fix: `expect(a == b)` written through a member named `expect` (`std.testing.expect`)
/// becomes `expectEqual(literal, other)` where exactly one side is a literal (it is the expected
/// value, so Z042 has nothing to say of the result). Through an alias, or with no literal side or
/// two, there is no fix.
fn rewrite(c: *Context, tree: *const Ast, callee: Ast.Node.Index, comparison: Ast.Node.Index, edits: *std.ArrayList(Report.Edit)) Context.Error!bool {
    if (tree.nodeTag(callee) != .field_access) return false;
    const name = tree.nodeData(callee).node_and_token[1];
    if (!std.mem.eql(u8, tree.tokenSlice(name), "expect")) return false;
    const lhs, const rhs = tree.nodeData(comparison).node_and_node;
    const left = literal(tree, lhs);
    if (left == literal(tree, rhs)) return false;
    const expected, const actual = if (left) .{ lhs, rhs } else .{ rhs, lhs };
    const span = tree.tokenToSpan(name);
    try edits.append(c.allocator, .{ .start = span.start, .end = span.end, .text = "expectEqual" });
    const start = tree.tokenStart(tree.firstToken(comparison));
    const end = tree.tokenToSpan(tree.lastToken(comparison)).end;
    try edits.append(c.allocator, .{ .start = start, .end = end, .text = try c.allocator.print("{s}, {s}", .{ tree.getNodeSource(expected), tree.getNodeSource(actual) }) });
    return true;
}

/// Whether an expression is written as a value literal: what Z042 reads as one but an enum
/// literal, which may stand for a tagged union's tag.
fn literal(tree: *const Ast, node: Ast.Node.Index) bool {
    const at = Written.ungrouped(tree, node);
    return switch (tree.nodeTag(at)) {
        .number_literal, .char_literal, .string_literal, .multiline_string_literal => true,
        .negation => literal(tree, tree.nodeData(at).node),
        .identifier => blk: {
            const spelled = tree.tokenSlice(tree.nodeMainToken(at));
            for ([_][]const u8{ "null", "true", "false" }) |each| {
                if (std.mem.eql(u8, spelled, each)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

const breadth = @import("breadth_test.zig");

test "breadth: expect comparison: the fix writes expectEqual with the literal first, only with one literal side" {
    try breadth.expectFixes(check, "const std = @import(\"std\"); test { const a: u32 = 1; try std.testing.expect(a == 1); }", 1, &.{ "expectEqual", "1, a" });
    try breadth.expectFixes(check, "const std = @import(\"std\"); test { const a: ?u32 = 1; try std.testing.expect(null == a); }", 1, &.{ "expectEqual", "null, a" });
    try breadth.expectFixes(check, "const std = @import(\"std\"); test { try std.testing.expect(1 == 1); }", 1, &.{});
    try breadth.expectFixes(check, "const std = @import(\"std\"); const expect = std.testing.expect; test { const a: u32 = 1; try expect(a == 1); }", 1, &.{});
}

test "breadth: expect comparison: an equality reported, through an alias too; another argument or callee not" {
    try breadth.expectFindings(check, "const std = @import(\"std\"); test { const a: u32 = 1; try std.testing.expect(a == 1); try std.testing.expect((a == 2)); try std.testing.expect(a != 2); }", 2);
    try breadth.expectFindings(check, "const std = @import(\"std\"); const expect = std.testing.expect; test { const a: u32 = 1; try expect(a == 1); }", 1);
    try breadth.expectFindings(check, "const std = @import(\"std\"); test { const a: u32 = 1; try std.testing.expect(a < 2); try std.testing.expectEqual(1, a); }", 0);
    try breadth.expectFindings(check, "fn expect(ok: bool) !void { _ = ok; } test { const a: u32 = 1; try expect(a == 1); }", 0);
}

test "breadth: expect comparison: an enum literal side, or no literal side, not reported: either may be a tagged union's tag" {
    try breadth.expectFindings(check, "const std = @import(\"std\"); const U = union(enum) { a: u32, b }; test { const u: U = .b; try std.testing.expect(u == .b); }", 0);
    try breadth.expectFindings(check, "const std = @import(\"std\"); const U = union(enum) { a: u32, b }; test { const u: U = .b; const t: std.meta.Tag(U) = .b; try std.testing.expect(u == t); }", 0);
}
