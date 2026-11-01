// review 5: c/c11_ast_token_start.zig
const std = @import("std");
const aegis = @import("aegis");
const Front = struct { tree: std.zig.Ast };
fn parseZig(gpa: std.mem.Allocator, source: []const u8) error{OutOfMemory}!Front {
    return .{ .tree = try std.zig.Ast.parse(gpa, @ptrCast(source), .zig) };
}
pub fn f(gpa: std.mem.Allocator, r: *std.Io.Reader) !u8 {
    const table: [16]u8 = @splat(0);
    const front = try aegis.input.Untrusted([]const u8).init(try r.take(4096)).parse(gpa, parseZig);
    return table[front.tree.tokenStart(3)];
}
