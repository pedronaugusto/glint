// std's own reading under a check of the node's tag.
const std = @import("std");
const Ast = std.zig.Ast;
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !?Ast.Node.Index {
    const bytes = try r.take(16);
    var tree = try Ast.parse(gpa, try gpa.dupeSentinel(u8, bytes, 0), .{});
    defer tree.deinit(gpa);
    const node: Ast.Node.Index = @enumFromInt(bytes[0]);
    if (tree.nodeTag(node) == .if_simple) return tree.fullIf(node).?.ast.then_expr;
    return null;
}
