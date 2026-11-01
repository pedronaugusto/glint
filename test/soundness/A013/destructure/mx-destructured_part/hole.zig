// matrix: the part destructured from a read asserted
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const kind, const extra = .{ try r.takeByte(), @as(u8, 0) };
    std.debug.assert(kind < 4);
    return kind + extra;
}
