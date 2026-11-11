const std = @import("std");
const P = struct { data: u32 };
pub fn f(w: *std.Io.Writer, g: *const P) !void {
    try w.print("{any}", .{g.*});
}
