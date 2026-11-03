const std = @import("std");
const err = @import("aegis").err;
const Holder = struct { source: err.PublicSource };
// The source's bytes overwritten through a pointer the caller passes: its holder is a
// parameter, but what it points at is the caller's memory, which can be written.
pub fn f(h: *Holder, secret: []const u8) void {
    @memcpy(std.mem.asBytes(&h.source)[0..@sizeOf([]const u8)], std.mem.asBytes(&secret));
}
