// review 5: t/t05_ptr_declared_in_branch.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var i: usize = 0;
    if (flag == 1) {
        const p = &i;
        p.* = 1000;
    }
    return buf[i];
}
