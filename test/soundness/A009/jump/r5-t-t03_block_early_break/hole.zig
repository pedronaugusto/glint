// review 5: t/t03_block_early_break.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var i: usize = 0;
    blk: {
        if (flag == 1) break :blk;
        i = 1000;
    }
    return buf[i];
}
