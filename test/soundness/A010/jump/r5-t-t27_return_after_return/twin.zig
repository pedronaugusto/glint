// review 5: t/t27_return_after_return.zig
const std = @import("std");
fn g(flag: u8) usize {
    var v: usize = 0;
    if (flag == 1) return v;
    v = 1000;
    return v;
}
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    return buf[g(flag)];
}
