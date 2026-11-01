// warp-fast: the same loop whose cancellation point is io.checkCancel called through @call
const std = @import("std");
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    while (true) {
        try @call(.auto, std.Io.checkCancel, .{io});
        n +%= 1;
    }
}
