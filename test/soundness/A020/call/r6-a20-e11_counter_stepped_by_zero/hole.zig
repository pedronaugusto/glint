// review 6: a20/e11_counter_stepped_by_zero.zig
const std = @import("std");
// Stepped by a step that is zero: never reaches the period.
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    var i: u64 = 1;
    const step: u64 = 0;
    while (true) {
        i += step;
        if (i % 64 == 0) try io.checkCancel();
        n +%= 1;
    }
}
