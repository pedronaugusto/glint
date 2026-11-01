// review 5: t/t01_call_writes_param.zig
const std = @import("std");
fn set(p: *usize) void {
    p.* = 1000;
}
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var i: usize = 0;
    if (flag == 1) set(&i);
    return buf[i];
}
