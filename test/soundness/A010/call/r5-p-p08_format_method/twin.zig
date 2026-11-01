// review 5: p/p08_format_method.zig
const std = @import("std");
const table: [16]u8 = @splat(0);
const V = struct {
    n: u32,
    pub fn format(self: V, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte(table[self.n]);
    }
};
pub fn f(r: *std.Io.Reader, w: *std.Io.Writer) !void {
    const v: V = .{ .n = try r.takeInt(u32, .little) };
    try w.print("{f}", .{v});
}
