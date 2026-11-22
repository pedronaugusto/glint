// A001: a Secret's address formatted by `{*}`: std writes the pointer and reads none of its
// fields.
const aegis = @import("aegis");
const std = @import("std");
pub fn show(w: *std.Io.Writer, s: *const aegis.Secret([32]u8)) !void {
    try w.print("{*}", .{s});
}
