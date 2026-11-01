// review 5: a20/c19_callee_typeof.zig
const std = @import("std");
fn tick(io: std.Io) !void {
    _ = @TypeOf(try io.checkCancel());
}
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    while (true) {
        try tick(io);
        n +%= 1;
    }
}
