// review 5: t/t04_and_rhs.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var i: usize = 0;
    _ = flag == 1 and blk: {
        i = 1000;
        break :blk true;
    };
    return buf[i];
}
