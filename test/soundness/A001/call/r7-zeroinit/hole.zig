const std = @import("std");
const err = @import("aegis").err;
// A public source made by std.mem.zeroInit: no classify, no reason.
pub fn f(secret: []const u8) err.PublicSource {
    return std.mem.zeroInit(err.PublicSource, .{ .bytes = secret });
}
