// A001: the same helper over plain integers.
const std = @import("std");
const aegis = @import("aegis");
pub fn f(all: []const u32) []const u8 {
    return std.mem.sliceAsBytes(all);
}
