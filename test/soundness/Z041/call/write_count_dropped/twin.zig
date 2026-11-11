// Z041 twin: the same done the way the rule leaves
const std = @import("std");
pub fn put(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeAll(bytes);
}
