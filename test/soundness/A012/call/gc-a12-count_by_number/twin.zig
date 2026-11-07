// glint-c: std repeats bytes as often as a length the program holds: a length is no number
const std = @import("std");
pub fn f(r: *std.Io.Reader, w: *std.Io.Writer) !void {
    const got = try r.take(8);
    try w.splatBytesAll("ab", got.len);
}
