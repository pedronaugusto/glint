// matrix A009 aggregate: a struct literal holds a checked index, read back to index
const std = @import("std");
const At = struct { at: u8, kind: u8 };
pub fn f(r: *std.Io.Reader, table: *const [16]u8) !u8 {
    const b = try r.takeByte();
    if (b >= table.len) return error.Range;
    const h: At = .{ .at = b, .kind = 3 };
    return table[h.at];
}
