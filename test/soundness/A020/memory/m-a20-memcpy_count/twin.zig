// matrix A020 memory: the program's own bytes copied by @memcpy into a u32 bound the loop
const std = @import("std");
pub fn f(io: std.Io, out: *u64) !void {
    _ = io;
    var n: u32 = 0;
    @memcpy(std.mem.asBytes(&n), &[4]u8{ 16, 0, 0, 0 });
    var i: u32 = 0;
    while (i < n) : (i += 1) out.* +%= i;
}
