const std = @import("std");
const aegis = @import("aegis");
// std's formatter prints the guarded owner's fields, its data read with no guard.
pub fn f(w: *std.Io.Writer, g: *const aegis.Guarded(u32)) !void {
    try w.print("{any}", .{g.*});
}
