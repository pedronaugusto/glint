// A001: the same helper viewing the bytes as a plain integer.
const std = @import("std");
const aegis = @import("aegis");
pub fn f(b: *const [4]u8) *align(1) const u32 {
    return std.mem.bytesAsValue(u32, b);
}
