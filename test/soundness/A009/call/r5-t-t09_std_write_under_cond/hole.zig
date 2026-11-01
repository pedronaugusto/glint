// review 5: t/t09_std_write_under_cond.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const flag = try r.takeByte();
    var bytes: [8]u8 = @splat(0);
    if (flag == 1) std.mem.writeInt(u64, &bytes, 1000, .little);
    return buf[std.mem.readInt(u64, &bytes, .little)];
}
