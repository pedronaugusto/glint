// glint-b: an optional field set where null, then a callee that nulls it: the `.?` meets null
const std = @import("std");
const D = struct { closing: ?u8 = null, n: u8 = 0 };
fn reset(d: *D) void {
    d.closing = null;
}
pub fn f(d: *D, r: *std.Io.Reader) !u8 {
    if (d.closing == null) d.closing = try r.takeByte();
    reset(d);
    return d.closing.?;
}
