// review 6: fp/f03_whole_struct_from_bytes.zig
const std = @import("std");
const Ops = struct { fill: *const fn (*[4]u8) void, n: u32 };
fn whole(b: *[4]u8) void {
    b.* = .{ 1, 2, 3, 4 };
}
fn use(b: []const u8) void {
    std.debug.print("{any}\n", .{b});
}
var ops: Ops = .{ .fill = whole, .n = 0 };
// The whole struct copied over from another value: std.mem.swap through its address.
pub fn replace(other: *Ops) void {
    std.mem.swap(Ops, &ops, other);
}
pub fn run() void {
    var buf: [4]u8 = undefined;
    ops.fill(&buf);
    use(&buf);
}
