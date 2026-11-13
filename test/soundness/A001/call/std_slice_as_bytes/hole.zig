// A001: std.mem.sliceAsBytes reads governed values as bytes (review 8, M5).
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f(all: []const S) []const u8 {
    return std.mem.sliceAsBytes(all);
}
