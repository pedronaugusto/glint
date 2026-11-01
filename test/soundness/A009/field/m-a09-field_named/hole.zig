// matrix A009 field: @field names the part holding input, which indexes a table
const std = @import("std");
const At = struct { at: u8, kind: u8 };
pub fn f(r: *std.Io.Reader, table: *const [16]u8) !u8 {
    const h: At = .{ .at = try r.takeByte(), .kind = 3 };
    return table[@field(h, "at")];
}
