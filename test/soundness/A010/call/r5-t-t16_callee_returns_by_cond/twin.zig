// review 5: t/t16_callee_returns_by_cond.zig
const std = @import("std");
fn pick(flag: u8) usize {
    if (flag == 1) return 1000;
    return 0;
}
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    return buf[pick(flag)];
}
