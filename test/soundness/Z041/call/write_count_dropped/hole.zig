// Z041: the reported form
const std = @import("std");
pub fn put(w: *std.Io.Writer, bytes: []const u8) !void {
    _ = try w.write(bytes);
}
