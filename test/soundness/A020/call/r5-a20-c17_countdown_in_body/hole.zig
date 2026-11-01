// review 5: a20/c17_countdown_in_body.zig
const std = @import("std");
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    while (true) {
        var left: u64 = 5;
        left -= 1;
        if (left == 0) {
            left = 5;
            try io.checkCancel();
        }
        n +%= 1;
    }
}
