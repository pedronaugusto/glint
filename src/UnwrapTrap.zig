//! Ban, opt-in: an unwrap that traps where the optional is null: `x.?`, `x orelse unreachable`
//! and `if (x) |v| v else unreachable`, the same operation in three spellings. A safe build panics there; a fast one has
//! undefined behaviour. Each site outside a `test` block needs a reason written at it, or a seam.
//! A null is not an error, so neither is Z026's.
const Ast = @import("std").zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Written = @import("Written.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tag) {
            .unwrap_optional => {
                const token = tree.nodeData(node).node_and_token[1];
                if (c.inTest(token)) continue;
                try c.at(rule, token, "`.?` traps where the value is null: write the reason it never is at this site");
            },
            .@"orelse" => {
                const answer = Written.ungrouped(tree, tree.nodeData(node).node_and_node[1]);
                if (tree.nodeTag(answer) != .unreachable_literal) continue;
                const token = tree.nodeMainToken(node);
                if (c.inTest(token)) continue;
                try c.at(rule, token, "`orelse unreachable` traps where the value is null: write the reason it never is at this site");
            },
            else => {
                // The same unwrap as a branch: `if (x) |v| v else unreachable`, an optional's
                // payload captured, its null trapping.
                const branch = tree.fullIf(node) orelse continue;
                if (branch.payload_token == null or branch.error_token != null) continue;
                const answer = Written.ungrouped(tree, branch.ast.else_expr.unwrap() orelse continue);
                if (tree.nodeTag(answer) != .unreachable_literal) continue;
                const token = tree.nodeMainToken(answer);
                if (c.inTest(token)) continue;
                try c.at(rule, token, "`else unreachable` on an optional's capture traps where the value is null: write the reason it never is at this site");
            },
        }
    }
}

const breadth = @import("breadth_test.zig");

test "breadth: unwrap trap: .? and orelse unreachable reported; another orelse and test code not" {
    try breadth.expectFindings(check, "pub fn f(o: ?u8) u8 { return o.? + (o orelse unreachable); }", 2);
    try breadth.expectFindings(check, "pub fn f(o: ?u8) u8 { return o orelse 0; }", 0);
    try breadth.expectFindings(check, "test { const o: ?u8 = 1; _ = o.?; }", 0);
    try breadth.expectFindings(check, "pub fn f(o: ?u8) u8 { return if (o) |v| v else unreachable; }", 1);
    try breadth.expectFindings(check, "pub fn f(o: ?u8) u8 { return if (o) |v| v else 0; }", 0);
    try breadth.expectFindings(check, "fn g() !u8 { return 1; } pub fn f() u8 { return if (g()) |v| v else |_| unreachable; }", 0);
}
