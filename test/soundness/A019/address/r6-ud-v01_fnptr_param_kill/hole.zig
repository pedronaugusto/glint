// review 6: ud/v01_fnptr_param_kill.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
// A function pointer the caller gives: it may give the local undefined.
pub fn f(free: *const fn (*W) void) u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    free(&w);
    return w.data[0];
}
