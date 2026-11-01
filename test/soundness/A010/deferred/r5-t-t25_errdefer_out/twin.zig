// review 5: t/t25_errdefer_out.zig
const std = @import("std");
fn g(flag: u8, out: *usize) !void {
    errdefer out.* = 1000;
    if (flag == 1) return error.Bad;
}
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var i: usize = 0;
    g(flag, &i) catch {};
    return buf[i];
}
