// review 5: t/t26_defer_after_return.zig
const std = @import("std");
fn g(flag: u8, out: *usize) void {
    var v: usize = 0;
    defer out.* = v;
    if (flag == 1) return;
    v = 1000;
}
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var i: usize = 0;
    g(flag, &i);
    return buf[i];
}
