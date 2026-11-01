// review 6: a20/e14_counter_eq_large.zig
const std = @import("std");
// i == 64 fires once only; after it the loop runs on with no point.
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    var i: u64 = 0;
    while (true) {
        i += 1;
        if (i == 64) try io.checkCancel();
        n +%= 1;
    }
}
