// glint-b: the optional itself has its address taken and is nulled through it: the `.?` meets null
const std = @import("std");
const D = struct { closing: ?u8 = null };
pub fn f(d: *D, r: *std.Io.Reader) !u8 {
    if (d.closing == null) d.closing = try r.takeByte();
    const q = &d.closing;
    q.* = null;
    return d.closing.?;
}
