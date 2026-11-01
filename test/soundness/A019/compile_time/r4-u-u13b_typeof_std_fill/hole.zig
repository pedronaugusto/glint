// review 4: u/u13b_typeof_std_fill.zig
// A019: the same with std's fill (Io.random) inside @TypeOf.
const std = @import("std");
pub fn main(io: std.Io) u8 {
    var buf: [4]u8 = undefined;
    const T = @TypeOf(io.random(&buf));
    if (T != void) return 0;
    return buf[3];
}
