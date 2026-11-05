// glint-b: an optional field set where null, then a callee that writes another field only: still present
const std = @import("std");
const D = struct { closing: ?u8 = null, n: u8 = 0 };
fn count(d: *D) void {
    d.n +%= 1;
}
pub fn f(d: *D, r: *std.Io.Reader) !u8 {
    if (d.closing == null) d.closing = try r.takeByte();
    count(d);
    return d.closing.?;
}
