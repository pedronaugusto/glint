// glint-b: std's reading of a switch case of a node of another tree's switch
const std = @import("std");
const Ast = std.zig.Ast;
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    const bytes = try r.take(16);
    var tree = try Ast.parse(gpa, try gpa.dupeSentinel(u8, bytes, 0), .{});
    defer tree.deinit(gpa);
    var other = try Ast.parse(gpa, try gpa.dupeSentinel(u8, bytes[1..], 0), .{});
    defer other.deinit(gpa);
    const node: Ast.Node.Index = @enumFromInt(bytes[0]);
    const whole = other.fullSwitch(node) orelse return 0;
    var total: usize = 0;
    for (whole.ast.cases) |case| total += tree.fullSwitchCase(case).?.ast.values.len;
    return total;
}
