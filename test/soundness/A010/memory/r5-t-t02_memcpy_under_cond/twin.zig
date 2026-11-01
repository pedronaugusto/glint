// review 5: t/t02_memcpy_under_cond.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var i: [1]usize = .{0};
    const k: [1]usize = .{1000};
    if (flag == 1) @memcpy(&i, &k);
    return buf[i[0]];
}
