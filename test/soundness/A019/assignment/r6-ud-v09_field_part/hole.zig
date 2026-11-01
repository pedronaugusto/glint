// review 6: ud/v09_field_part.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
fn kill(d: *[4]u8) void {
    d.* = undefined;
}
// A part of the local handed by address.
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    kill(&w.data);
    return w.data[0];
}
