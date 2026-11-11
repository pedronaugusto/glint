//! Hygiene: `std.testing.expect(a == b)`, where `expectEqual` says the same and prints
//! both values when it fails; `expect` prints nothing. Read: a call whose every callee is std's
//! `testing.expect` (`Governed.stdCall`, through aliases), its argument written `==`
//! through parentheses. `!=` and other comparisons are left: expectEqual says none of them. A callee that does not resolve is silent.
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
        if (written.len != 1) continue;
        const operator = tree.nodeTag(Written.ungrouped(tree, written[0]));
        if (operator != .equal_equal) continue;
        if (try Governed.stdCall(c, call.node, "testing.expect") != .yes) continue;
        try c.at(rule, tree.nodeMainToken(call.node), "std.testing.expect of `a == b`: expectEqual(expected, actual) says the same and prints both values when it fails");
    }
}

const breadth = @import("breadth.zig");

test "breadth: expect comparison: an equality reported, through an alias too; another argument or callee not" {
    try breadth.expectFindings(check, "const std = @import(\"std\"); test { const a: u32 = 1; try std.testing.expect(a == 1); try std.testing.expect((a == 2)); try std.testing.expect(a != 2); }", 2);
    try breadth.expectFindings(check, "const std = @import(\"std\"); const expect = std.testing.expect; test { const a: u32 = 1; try expect(a == 1); }", 1);
    try breadth.expectFindings(check, "const std = @import(\"std\"); test { const a: u32 = 1; try std.testing.expect(a < 2); try std.testing.expectEqual(1, a); }", 0);
    try breadth.expectFindings(check, "fn expect(ok: bool) !void { _ = ok; } test { const a: u32 = 1; try expect(a == 1); }", 0);
}
