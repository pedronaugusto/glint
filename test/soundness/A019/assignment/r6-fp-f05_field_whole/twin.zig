// review 6: fp/f05_field_whole.zig
const std = @import("std");
const Ops = struct { fill: *const fn (*[4]u8) void };
fn whole(b: *[4]u8) void {
    b.* = .{ 1, 2, 3, 4 };
}
fn use(b: []const u8) void {
    std.debug.print("{any}\n", .{b});
}
pub fn run(ops: *const Ops) void {
    var buf: [4]u8 = undefined;
    ops.fill(&buf);
    use(&buf);
}
pub fn make() Ops {
    return .{ .fill = whole };
}
