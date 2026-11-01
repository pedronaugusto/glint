// review 5: c/c10_ast_location_line.zig
const std = @import("std");
const aegis = @import("aegis");
const Front = struct { tree: std.zig.Ast };
fn parseZig(gpa: std.mem.Allocator, source: []const u8) error{OutOfMemory}!Front {
    return .{ .tree = try std.zig.Ast.parse(gpa, @ptrCast(source), .zig) };
}
pub fn f(gpa: std.mem.Allocator, r: *std.Io.Reader) !u8 {
    const table: [16]u8 = @splat(0);
    const front = try aegis.input.Untrusted([]const u8).init(try r.take(4096)).parse(gpa, parseZig);
    const loc = front.tree.tokenLocation(0, 3);
    return table[loc.line];
}
