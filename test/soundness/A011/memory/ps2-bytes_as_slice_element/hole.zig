// std's Duration read out as a raw count through an element of std.mem.bytesAsSlice over its bytes.
const std = @import("std");
pub fn f(d: std.Io.Duration) i96 {
    var copy = d;
    return @divTrunc(std.mem.bytesAsSlice(i96, std.mem.asBytes(&copy))[0], 1000);
}
