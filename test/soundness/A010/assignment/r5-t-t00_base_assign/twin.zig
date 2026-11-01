// review 5: t/t00_base_assign.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var i: usize = 0;
    if (flag == 1) i = 1000;
    return buf[i];
}
