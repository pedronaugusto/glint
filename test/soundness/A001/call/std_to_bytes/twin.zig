// A001: the bytes the type exposes, copied out.
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f(s: *const S) [4]u8 {
    return std.mem.toBytes(s.expose().*);
}
