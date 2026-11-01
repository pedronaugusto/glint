// review 5: a20/c04b_io.zig
const std = @import("std");
pub fn spin(io: std.Io) void {
    _ = io;
    var n: u64 = 0;
    while (true) n +%= 1;
}
