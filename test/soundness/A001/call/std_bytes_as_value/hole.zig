// A001: std.mem.bytesAsValue views the caller's bytes as a governed value (review 8, M5).
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f(b: *const [4]u8) *const S {
    return std.mem.bytesAsValue(S, b);
}
