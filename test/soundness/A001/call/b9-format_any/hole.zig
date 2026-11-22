// A001: a Secret formatted by `{any}`: std's default format walks its fields and writes the
// material, past the Secret's own refusing `format`.
const aegis = @import("aegis");
const std = @import("std");
pub fn show(w: *std.Io.Writer, s: aegis.Secret([32]u8)) !void {
    try w.print("{any}", .{s});
}
