const std = @import("std");
pub fn g0(r: *std.Io.Reader) !u32 {
    return r.takeInt(u32, .little);
}
