// review 6: fp/f02b_assign_store.zig
const std = @import("std");
const Ops = struct { fill: *const fn (*[4]u8) void, n: u32 };
fn whole(b: *[4]u8) void {
    b.* = .{ 1, 2, 3, 4 };
}
fn none(b: *[4]u8) void {
    _ = b;
}
fn use(b: []const u8) void {
    std.debug.print("{any}\n", .{b});
}
var ops: Ops = .{ .fill = whole, .n = 0 };
pub fn swap() void {
    ops.fill = none;
    ops.n = 1;
}
pub fn run() void {
    var buf: [4]u8 = undefined;
    ops.fill(&buf);
    use(&buf);
}
