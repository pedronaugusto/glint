// glint-b: A001 memory (bytes read): the unsafe shape, which must flag
const std = @import("std");
const aegis = @import("aegis");
pub fn f(s: *const aegis.Secret(u64)) [8]u8 {
    return std.mem.toBytes(s.*);
}
