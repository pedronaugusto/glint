// A001: std.mem.bytesAsSlice views the caller's bytes as governed values (review 8, M5).
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f(b: []const u8) []align(1) const S {
    return std.mem.bytesAsSlice(S, b);
}
