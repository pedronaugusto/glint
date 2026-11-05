// glint-b: a file's own optional field set where null, then a callee that nulls it: the `.?` meets null
const std = @import("std");
const Self = @This();
closing: ?u8 = null,
n: u8 = 0,
fn reset(d: *Self) void {
    d.closing = null;
}
pub fn f(d: *Self, r: *std.Io.Reader) !u8 {
    if (d.closing == null) d.closing = try r.takeByte();
    reset(d);
    return d.closing.?;
}
