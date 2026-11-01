// review 5: a20/c02c_nopoint.zig
const std = @import("std");
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    while (true) {
        _ = io;
        n +%= 1;
    }
}
