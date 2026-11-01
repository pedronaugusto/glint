// warp-fast: a word cast to an atomic cell's pointer and copied out by value.
const std = @import("std");
pub fn f(p: *u32) u32 {
    var cell = @as(*std.atomic.Value(u32), @ptrCast(p)).*;
    return cell.load(.acquire);
}
