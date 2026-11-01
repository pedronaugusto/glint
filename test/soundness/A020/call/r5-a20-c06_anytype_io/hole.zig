// review 5: a20/c06_anytype_io.zig
const std = @import("std");
pub fn spin(io: anytype) void {
    _ = io;
    var n: u64 = 0;
    while (true) n +%= 1;
}
pub fn start(io: std.Io) void {
    spin(io);
}
