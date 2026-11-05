// glint-b: an optional field set where null, then nulled through another pointer of its type: the `.?` meets null
const std = @import("std");
const D = struct { closing: ?u8 = null };
pub fn f(d: *D, e: *D, r: *std.Io.Reader) !u8 {
    if (d.closing == null) d.closing = try r.takeByte();
    e.closing = null;
    return d.closing.?;
}
