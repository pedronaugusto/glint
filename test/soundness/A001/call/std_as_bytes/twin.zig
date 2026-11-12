// A001: the bytes the type exposes, read as bytes.
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f(s: *const S) []const u8 {
    return std.mem.asBytes(s.expose());
}
