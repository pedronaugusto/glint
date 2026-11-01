// matrix: a factor std's constant gives, computed in a comptime block and multiplied in at run time
const std = @import("std");
pub fn f(ms: u64) u64 {
    const factor = comptime blk: {
        break :blk std.time.ns_per_ms;
    };
    return ms * factor;
}
