// glint-b: only its payload has its address taken (`&d.closing.?`): a write through it keeps the value
const std = @import("std");
const D = struct { closing: ?u8 = null };
pub fn f(d: *D, r: *std.Io.Reader) !u8 {
    if (d.closing == null) d.closing = try r.takeByte();
    const q = &d.closing.?;
    q.* +%= 1;
    return d.closing.?;
}
