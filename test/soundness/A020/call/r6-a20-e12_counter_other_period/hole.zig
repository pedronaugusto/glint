// review 6: a20/e12_counter_other_period.zig
const std = @import("std");
// Stepped by 2 from 1: odd forever, never a multiple of 64.
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    var i: u64 = 1;
    while (true) {
        i += 2;
        if (i % 64 == 0) try io.checkCancel();
        n +%= 1;
    }
}
