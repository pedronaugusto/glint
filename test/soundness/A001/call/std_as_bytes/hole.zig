// A001: std.mem.asBytes reads a governed value's state as bytes (review 8, M5).
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f(s: *const S) []const u8 {
    return std.mem.asBytes(s);
}
