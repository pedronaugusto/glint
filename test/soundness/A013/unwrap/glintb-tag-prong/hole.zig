// glint-b: std's reading of a node a peer names, in a prong of tags it returns null on
const std = @import("std");
const Ast = std.zig.Ast;
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !?Ast.Node.Index {
    const bytes = try r.take(16);
    var tree = try Ast.parse(gpa, try gpa.dupeZ(u8, bytes), .zig);
    defer tree.deinit(gpa);
    const node: Ast.Node.Index = @enumFromInt(bytes[0]);
    return switch (tree.nodeTag(node)) {
        .@"while", .while_simple => tree.fullIf(node).?.ast.then_expr,
        else => null,
    };
}
