// review 5: t/t11b_assign_elem_base.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var i: [1]usize = .{0};
    if (flag == 1) i[0] = 1000;
    return buf[i[0]];
}
