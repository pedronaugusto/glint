// review 5: a20/c16_periodic_counter_in_body.zig
const std = @import("std");
// The counter is declared afresh each pass: i is 1 at the test on every pass, so the point never runs.
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    while (true) {
        var i: u64 = 0;
        i += 1;
        if (i % 64 == 0) try io.checkCancel();
        n +%= 1;
    }
}
