// review 6: ud/v05_at_call.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
fn kill(w: *W) void {
    w.* = undefined;
}
// The same call through @call.
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    @call(.auto, kill, .{&w});
    return w.data[0];
}
