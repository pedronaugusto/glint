// review 6: ud/v08_ptr_local.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
fn kill(w: *W) void {
    w.* = undefined;
}
// The address handed through a pointer local made before the call.
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    const p = &w;
    kill(p);
    return w.data[0];
}
