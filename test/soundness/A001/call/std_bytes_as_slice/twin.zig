// A001: the same helper viewing the bytes as plain integers.
const std = @import("std");
const aegis = @import("aegis");
pub fn f(b: []const u8) []align(1) const u32 {
    return std.mem.bytesAsSlice(u32, b);
}
