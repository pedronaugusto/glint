// review 6: a20/e13_counter_shadow_cond.zig
const std = @import("std");
// The periodic test reads a different variable than the one stepped.
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    var i: u64 = 0;
    const j: u64 = 1;
    while (true) {
        i += 1;
        if (j % 64 == 0) try io.checkCancel();
        n +%= i;
    }
}
