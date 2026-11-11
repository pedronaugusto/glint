//! Ban, opt-in: an unwrap that traps where the optional is null: `x.?` and `x orelse
//! unreachable`, the same operation in two spellings. A safe build panics there; a fast one has
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
            else => {},
        }
    }
}

const breadth = @import("breadth.zig");

test "breadth: unwrap trap: .? and orelse unreachable reported; another orelse and test code not" {
    try breadth.expectFindings(check, "pub fn f(o: ?u8) u8 { return o.? + (o orelse unreachable); }", 2);
    try breadth.expectFindings(check, "pub fn f(o: ?u8) u8 { return o orelse 0; }", 0);
    try breadth.expectFindings(check, "test { const o: ?u8 = 1; _ = o.?; }", 0);
}
