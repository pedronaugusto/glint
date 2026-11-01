// review 6: a01/r03_whole_copy_bytes.zig
const std = @import("std");
const err = @import("aegis").err;
// The source's bytes overwritten through asBytes of the whole value: no field named.
pub fn f(secret: []const u8) err.PublicSource {
    var p = err.PublicSource.classify("fixed label", "ok");
    @memcpy(std.mem.asBytes(&p)[0..@sizeOf([]const u8)], std.mem.asBytes(&secret));
    return p;
}
