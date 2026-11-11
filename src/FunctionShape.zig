//! Policy, opt-in: a function with more parameters, or deeper nesting, than the project allows,
//! a metric as P003 (length) is. Counted: every parameter its prototype declares, `comptime`
//! and `anytype` ones included; and the deepest nesting of `if`, `while`, `for` and `switch` in
//! its body, each one inside another adding a level (an `else if` is the same level as its `if`;
//! a nested function or container is its own). TODO(0.8): the limits are configuration once the
//! rule is registered.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Model = @import("Model.zig");

pub const Limits = struct { parameters: usize = 7, nesting: usize = 5 };

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    return checkLimits(c, rule, .{});
}

pub fn checkLimits(c: *Context, rule: Rule, limits: Limits) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations) |decl| {
        if (decl.kind != .function or c.inTest(decl.token)) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, decl.node) orelse continue;
        var count: usize = 0;
        var it = proto.iterate(tree);
        while (it.next()) |_| count += 1;
        if (count > limits.parameters) try c.at(rule, decl.token, try c.allocator.print("'{s}' takes {d} parameters, above the {d} allowed", .{ decl.name, count, limits.parameters }));
        const parent = model.parentOf(decl.node) orelse continue;
        if (tree.nodeTag(parent) != .fn_decl) continue;
        const deepest = depthUnder(tree, model, parent);
        if (deepest > limits.nesting) try c.at(rule, decl.token, try c.allocator.print("'{s}' nests {d} levels deep, above the {d} allowed", .{ decl.name, deepest, limits.nesting }));
    }
}

/// The deepest nesting of control flow under the function `function`.
fn depthUnder(tree: *const Ast, model: *const Model, function: Ast.Node.Index) usize {
    var deepest: usize = 0;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (!flow(tree, node)) continue;
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        var depth: usize = 1;
        var at = node;
        const inside = while (model.parentOf(at)) |parent| : (at = parent) {
            if (parent == function) break true;
            if (tree.nodeTag(parent) == .fn_decl) break false;
            var members: [2]Ast.Node.Index = undefined;
            if (tree.fullContainerDecl(&members, parent) != null) break false;
            if (!flow(tree, parent)) continue;
            // An `else if` continues its `if`'s level.
            if (tree.fullIf(parent)) |branch| if (branch.ast.else_expr.unwrap() == at and tree.fullIf(at) != null) continue;
            depth += 1;
        } else false;
        if (inside) deepest = @max(deepest, depth);
    }
    return deepest;
}

fn flow(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.fullIf(node) != null or tree.fullWhile(node) != null or tree.fullFor(node) != null or tree.fullSwitch(node) != null;
}

const breadth = @import("breadth.zig");

test "breadth: function shape: too many parameters, too deep a nesting reported; an else-if chain one level" {
    try breadth.expectFindings(check, "pub fn f(a: u8, b: u8, c: u8, d: u8, e: u8, f2: u8, g: u8, h: u8) void { _ = .{ a, b, c, d, e, f2, g, h }; }", 1);
    try breadth.expectFindings(check, "pub fn f(a: u8) void { if (a > 0) { if (a > 1) { if (a > 2) { if (a > 3) { if (a > 4) { if (a > 5) {} } } } } } }", 1);
    try breadth.expectFindings(check, "pub fn f(a: u8) u8 { if (a == 0) return 0 else if (a == 1) return 1 else if (a == 2) return 2 else if (a == 3) return 3 else if (a == 4) return 4 else if (a == 5) return 5; return 9; }", 0);
    try breadth.expectFindings(check, "pub fn f(a: u8, b: u8) void { _ = a; _ = b; }", 0);
}
