// review 5: t/t08_loop_call_bump.zig
const std = @import("std");
fn bump(p: *usize) void {
    p.* += 1;
}
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    var flag = try r.takeByte();
    var i: usize = 0;
    while (flag == 0) {
        bump(&i);
        flag = try r.takeByte();
    }
    return buf[i];
}
