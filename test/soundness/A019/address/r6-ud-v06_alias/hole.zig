// review 6: ud/v06_alias.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
fn kill(w: *W) void {
    w.* = undefined;
}
const k = kill;
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    k(&w);
    return w.data[0];
}
