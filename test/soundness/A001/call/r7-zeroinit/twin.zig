const std = @import("std");
const err = @import("aegis").err;
const Text = struct { bytes: []const u8 };
pub fn f(secret: []const u8) Text {
    return std.mem.zeroInit(Text, .{ .bytes = secret });
}
