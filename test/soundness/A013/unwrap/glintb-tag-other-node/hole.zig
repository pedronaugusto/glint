// glint-b: std's reading of one node under a check of another's tag
const std = @import("std");
const Ast = std.zig.Ast;
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !?Ast.Node.Index {
    const bytes = try r.take(16);
    var tree = try Ast.parse(gpa, try gpa.dupeZ(u8, bytes), .zig);
    defer tree.deinit(gpa);
    const node: Ast.Node.Index = @enumFromInt(bytes[0]);
    const other: Ast.Node.Index = @enumFromInt(bytes[1]);
    if (tree.nodeTag(other) == .if_simple) return tree.fullIf(node).?.ast.then_expr;
    return null;
}
