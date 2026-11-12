// A013: std.debug.assert is gone in ReleaseFast.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(n: u32) u32 {
    std.debug.assert(n > 0);
    return n - 1;
}
