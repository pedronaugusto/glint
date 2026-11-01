// review 5: t/t06_capture_ptr_in_branch.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var i: [1]usize = .{0};
    if (flag == 1) {
        for (&i) |*e| e.* = 1000;
    }
    return buf[i[0]];
}
