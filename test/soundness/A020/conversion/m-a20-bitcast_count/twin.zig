// matrix A020 conversion: the program's own bytes reinterpreted by @bitCast bound the loop
const std = @import("std");
pub fn f(io: std.Io, out: *u64) !void {
    _ = io;
    const n: u32 = @bitCast([4]u8{ 16, 0, 0, 0 });
    var i: u32 = 0;
    while (i < n) : (i += 1) out.* +%= i;
}
