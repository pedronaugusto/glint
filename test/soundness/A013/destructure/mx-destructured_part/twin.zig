// matrix: the constant part destructured beside a read asserted
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const kind, const extra = .{ try r.takeByte(), @as(u8, 0) };
    std.debug.assert(extra < 4);
    if (kind >= 4) return error.Bad;
    return kind + extra;
}
