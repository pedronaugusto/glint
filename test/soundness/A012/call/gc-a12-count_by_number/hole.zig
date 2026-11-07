// glint-c: std repeats bytes as often as a number from input says, through its own parameter
const std = @import("std");
pub fn f(r: *std.Io.Reader, w: *std.Io.Writer) !void {
    const n = try r.takeInt(u32, .little);
    try w.splatBytesAll("ab", n);
}
