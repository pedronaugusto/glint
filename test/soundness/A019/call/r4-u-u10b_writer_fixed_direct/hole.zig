// review 4: u/u10b_writer_fixed_direct.zig
// baseline: the same read straight from the local (expected flagged)
const std = @import("std");
pub fn main() !u8 {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("ab");
    return buf[10];
}
