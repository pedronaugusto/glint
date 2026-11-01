// review 5: c/c10d_parser_location_in_parser.zig
const std = @import("std");
const aegis = @import("aegis");
const Front = struct { line: usize };
fn parseZig(gpa: std.mem.Allocator, source: []const u8) error{OutOfMemory}!Front {
    const tree = try std.zig.Ast.parse(gpa, @ptrCast(source), .zig);
    return .{ .line = tree.tokenLocation(0, 3).line };
}
pub fn f(gpa: std.mem.Allocator, r: *std.Io.Reader) !u8 {
    const table: [16]u8 = @splat(0);
    const front = try aegis.input.Untrusted([]const u8).init(try r.take(4096)).parse(gpa, parseZig);
    return table[front.line];
}
