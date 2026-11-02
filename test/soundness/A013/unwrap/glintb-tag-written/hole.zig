// glint-b: std's reading of a node whose tag was checked, the node written between
const std = @import("std");
const Ast = std.zig.Ast;
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !?Ast.Node.Index {
    const bytes = try r.take(16);
    var tree = try Ast.parse(gpa, try gpa.dupeZ(u8, bytes), .zig);
    defer tree.deinit(gpa);
    var node: Ast.Node.Index = @enumFromInt(bytes[0]);
    if (tree.nodeTag(node) != .if_simple) return null;
    node = @enumFromInt(bytes[1]);
    return tree.fullIf(node).?.ast.then_expr;
}
