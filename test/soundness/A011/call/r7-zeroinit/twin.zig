const std = @import("std");
const P = struct { nanoseconds: i96 = 0 };
pub fn f(ms: i96) P {
    return std.mem.zeroInit(P, .{ .nanoseconds = ms * 1000000 });
}
