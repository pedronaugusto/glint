// review 6: fp/f01_pub_ops_one_literal.zig
const std = @import("std");
// A public type: a consumer may store any function in fill. The one literal here writes whole.
pub const Ops = struct { fill: *const fn (*[4]u8) void };
fn whole(b: *[4]u8) void {
    b.* = .{ 1, 2, 3, 4 };
}
pub const default: Ops = .{ .fill = whole };
fn use(b: []const u8) void {
    std.debug.print("{any}\n", .{b});
}
pub fn run(ops: Ops) void {
    var buf: [4]u8 = undefined;
    ops.fill(&buf);
    use(&buf);
}
