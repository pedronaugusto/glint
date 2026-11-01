// review 5: t/t17_callee_cond_writes.zig
const std = @import("std");
fn set(flag: u8, p: *usize) void {
    if (flag == 1) p.* = 1000;
}
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var i: usize = 0;
    set(flag, &i);
    return buf[i];
}
