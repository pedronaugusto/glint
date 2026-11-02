// glint-b: std's reading of a node after `!= .tag) return`, nothing written between
const std = @import("std");
const Ast = std.zig.Ast;
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !?Ast.Node.Index {
    const bytes = try r.take(16);
    var tree = try Ast.parse(gpa, try gpa.dupeSentinel(u8, bytes, 0), .{});
    defer tree.deinit(gpa);
    const node: Ast.Node.Index = @enumFromInt(bytes[0]);
    if (tree.nodeTag(node) != .if_simple and tree.nodeTag(node) != .@"if") return null;
    return tree.fullIf(node).?.ast.then_expr;
}
