//! Hygiene: `std.testing.expectEqual(expected, actual)` (Zig 0.17's order, lib/std/testing.zig)
//! called with a literal second and a non-literal first: the failure then prints the value the
//! test computed as the one it expected. Read: a call whose every callee is std's
//! `testing.expectEqual` (`Governed.stdCall`), its two arguments as written; a literal is a number,
//! a character, a string, an enum literal, `null`, `true`, `false` or `undefined`. Two literals or
//! two non-literals say nothing of the order.
const Ast = @import("std").zig.Ast;
const Context = @import("RuleContext.zig");
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
        if (written.len != 2) continue;
        if (literal(tree, written[0]) or !literal(tree, written[1])) continue;
        if (try Governed.stdCall(c, call.node, "testing.expectEqual") != .yes) continue;
        try c.at(rule, tree.nodeMainToken(call.node), "expectEqual takes (expected, actual): the literal is second, so a failure names the computed value as the expected one; swap the arguments");
    }
}

/// Whether an expression is written as a literal value.
fn literal(tree: *const Ast, node: Ast.Node.Index) bool {
    const at = Written.ungrouped(tree, node);
    return switch (tree.nodeTag(at)) {
        .number_literal, .char_literal, .string_literal, .multiline_string_literal, .enum_literal => true,
        .negation => literal(tree, tree.nodeData(at).node),
        .identifier => blk: {
            const name = tree.tokenSlice(tree.nodeMainToken(at));
            for ([_][]const u8{ "null", "true", "false", "undefined" }) |each| {
                if (@import("std").mem.eql(u8, name, each)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

const breadth = @import("breadth_test.zig");

test "breadth: expectEqual order: a literal second reported; literal first, two literals, two values not" {
    try breadth.expectFindings(check, "const std = @import(\"std\"); test { const a: u32 = 1; try std.testing.expectEqual(a, 1); try std.testing.expectEqual(a, .x); }", 2);
    try breadth.expectFindings(check, "const std = @import(\"std\"); test { const a: ?u32 = null; try std.testing.expectEqual(a, null); try std.testing.expectEqual(a, -1); }", 2);
    try breadth.expectFindings(check, "const std = @import(\"std\"); test { const a: u32 = 1; try std.testing.expectEqual(1, a); }", 0);
    try breadth.expectFindings(check, "const std = @import(\"std\"); test { try std.testing.expectEqual(1, 1); }", 0);
    try breadth.expectFindings(check, "const std = @import(\"std\"); test { const a: u32 = 1; const b: u32 = 1; try std.testing.expectEqual(a, b); }", 0);
    try breadth.expectFindings(check, "fn expectEqual(a: u32, b: u32) !void { _ = a; _ = b; } test { const a: u32 = 1; try expectEqual(a, 1); }", 0);
}
