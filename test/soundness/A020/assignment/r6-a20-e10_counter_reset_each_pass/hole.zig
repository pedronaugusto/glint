// review 6: a20/e10_counter_reset_each_pass.zig
const std = @import("std");
// The counter is declared before the loop but reset each pass: i is 1 at the test every pass.
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    var i: u64 = 0;
    while (true) {
        i = 0;
        i += 1;
        if (i % 64 == 0) try io.checkCancel();
        n +%= 1;
    }
}
