// glint-b: an optional field set where null, then read: it holds a value on both paths (Bounds presence)
const std = @import("std");
const D = struct { closing: ?u8 = null };
pub fn f(d: *D, r: *std.Io.Reader) !u8 {
    if (d.closing == null) d.closing = try r.takeByte();
    return d.closing.?;
}
