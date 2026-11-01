// review 5: a20/c16c_periodic_never.zig
const std = @import("std");
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    while (true) {
        if (n == 1) try io.checkCancel();
        n +%= 1;
    }
}
