const std = @import("std");
// std's Duration made from a raw count by std.mem.zeroInit.
pub fn f(ms: i96) std.Io.Duration {
    return std.mem.zeroInit(std.Io.Duration, .{ .nanoseconds = ms * 1000000 });
}
