const std = @import("std");
pub fn get(r: *std.Io.Reader) !u32 {
    return r.takeInt(u32, .little);
}
