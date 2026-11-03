const std = @import("std");
pub fn f(d: i96) i96 {
    var copy = d;
    return @divTrunc(std.mem.bytesAsSlice(i96, std.mem.asBytes(&copy))[0], 1000);
}
