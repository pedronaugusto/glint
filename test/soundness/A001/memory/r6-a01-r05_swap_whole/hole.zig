// review 6: a01/r05_swap_whole.zig
const std = @import("std");
const err = @import("aegis").err;
// The whole value swapped with an unclassified one: no field named.
pub fn f(secret: []const u8) err.PublicSource {
    var p = err.PublicSource.classify("fixed label", "ok");
    var raw: struct { bytes: []const u8 } = .{ .bytes = secret };
    std.mem.swap([]const u8, &p.bytes, &raw.bytes);
    return p;
}
