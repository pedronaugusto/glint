// A plain integer's bytes read back.
const std = @import("std");
pub fn f(n: i96) i96 {
    return @divTrunc(std.mem.readInt(i96, std.mem.asBytes(&n)[0..12], .little), 1000);
}
