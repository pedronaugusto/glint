// review 5: a20/c02_typeof_point.zig
const std = @import("std");
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    while (true) {
        _ = @TypeOf(try io.checkCancel());
        n +%= 1;
    }
}
