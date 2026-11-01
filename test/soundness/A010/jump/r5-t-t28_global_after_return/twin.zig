// review 5: t/t28_global_after_return.zig
const std = @import("std");
var state: usize = 0;
fn g(flag: u8) void {
    if (flag == 1) return;
    state = 1000;
}
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    g(flag);
    return buf[state];
}
