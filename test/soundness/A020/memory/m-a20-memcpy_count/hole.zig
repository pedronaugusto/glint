// matrix A020 memory: input's bytes copied by @memcpy into a u32 bound a loop with no cancellation point
const std = @import("std");
pub fn f(io: std.Io, r: *std.Io.Reader, out: *u64) !void {
    _ = io;
    var n: u32 = 0;
    @memcpy(std.mem.asBytes(&n), try r.take(4));
    var i: u32 = 0;
    while (i < n) : (i += 1) out.* +%= i;
}
