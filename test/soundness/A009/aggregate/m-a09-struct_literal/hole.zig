// matrix A009 aggregate: the checked byte is put in the literal's other field, so the field read back to index is unchecked
const std = @import("std");
const At = struct { at: u8, kind: u8 };
pub fn f(r: *std.Io.Reader, table: *const [16]u8) !u8 {
    const b = try r.takeByte();
    const d = try r.takeByte();
    if (b >= table.len) return error.Range;
    const h: At = .{ .at = d, .kind = b };
    return table[h.at];
}
