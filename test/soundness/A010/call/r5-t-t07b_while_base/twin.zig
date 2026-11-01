// review 5: t/t07b_while_base.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    var flag = try r.takeByte();
    var i: usize = 0;
    while (flag == 0) {
        i += 1;
        flag = try r.takeByte();
    }
    return buf[i];
}
