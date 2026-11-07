// glint-c: a format's runtime width from input pads by it
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const width = try r.takeInt(u32, .little);
    var buf: [256]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "{d:[1]}", .{ 7, width });
    return out.len;
}
