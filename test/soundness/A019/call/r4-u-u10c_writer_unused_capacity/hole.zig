// review 4: u/u10c_writer_unused_capacity.zig
// A019: a keep's own API hands back the unwritten part.
const std = @import("std");
pub fn main() !u8 {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("ab");
    return w.unusedCapacitySlice()[0];
}
