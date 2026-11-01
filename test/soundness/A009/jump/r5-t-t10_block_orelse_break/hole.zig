// review 5: t/t10_block_orelse_break.zig
const std = @import("std");
fn pick(flag: u8) ?u8 {
    return if (flag == 1) null else flag;
}
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var i: usize = 0;
    blk: {
        _ = pick(flag) orelse break :blk;
        i = 1000;
    }
    return buf[i];
}
