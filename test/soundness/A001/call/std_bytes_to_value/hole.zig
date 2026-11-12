// A001: std.mem.bytesToValue makes a governed type from bytes (review 8, M5).
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f(b: [4]u8) S {
    return std.mem.bytesToValue(S, &b);
}
