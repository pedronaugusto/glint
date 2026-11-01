// review 5: t/t05b_ptr_declared_outside.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var i: usize = 0;
    const p = &i;
    if (flag == 1) {
        p.* = 1000;
    }
    return buf[i];
}
