// matrix: std's writer repeats bytes a count from input times, through a parameter named splat
const std = @import("std");
pub fn f(r: *std.Io.Reader, w: *std.Io.Writer) !void {
    const n = try r.takeInt(u32, .little);
    try w.splatBytesAll("ab", n);
}
