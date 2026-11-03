// std's Duration read out as a raw integer by std.mem.readInt over its bytes.
const std = @import("std");
pub fn f(d: std.Io.Duration) i96 {
    return @divTrunc(std.mem.readInt(i96, std.mem.asBytes(&d)[0..12], .little), 1000);
}
