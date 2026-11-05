// glint-b: a file's own optional field set where null (a file is an auto-layout struct): present at the `.?`
const std = @import("std");
const Self = @This();
closing: ?u8 = null,
n: u8 = 0,
fn count(d: *Self) void {
    d.n +%= 1;
}
pub fn f(d: *Self, r: *std.Io.Reader) !u8 {
    if (d.closing == null) d.closing = try r.takeByte();
    count(d);
    return d.closing.?;
}
