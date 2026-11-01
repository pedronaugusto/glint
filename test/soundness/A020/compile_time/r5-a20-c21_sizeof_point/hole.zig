// review 5: a20/c21_sizeof_point.zig
const std = @import("std");
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    while (true) {
        n +%= @sizeOf(@TypeOf(io.checkCancel()));
    }
}
