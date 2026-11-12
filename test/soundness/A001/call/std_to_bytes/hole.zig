// A001: std.mem.toBytes copies a governed value's state out as bytes (review 8, M5).
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f(s: *const S) [@sizeOf(S)]u8 {
    return std.mem.toBytes(s.*);
}
