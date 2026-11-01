// review 5: a20/c16b_periodic_counter_outside.zig
const std = @import("std");
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    var i: u64 = 0;
    while (true) {
        i += 1;
        if (i % 64 == 0) try io.checkCancel();
        n +%= 1;
    }
}
