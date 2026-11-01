// review 6: ud/v14_callee_alias_store.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
// The callee writes undefined through a local copy of its pointer.
fn kill(w: *W) void {
    const q = w;
    q.* = undefined;
}
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    kill(&w);
    return w.data[0];
}
