// A013: std.debug.assert in a function's runtime body is gone in ReleaseFast, a comptime block
// beside it notwithstanding.
const aegis = @import("aegis");
const std = @import("std");
const max_inline = 6;
comptime {
    _ = max_inline;
}
pub fn f(n: u32) u32 {
    std.debug.assert(n <= max_inline);
    return n + 1;
}
