// matrix A020 conversion: input's bytes reinterpreted by @bitCast as a u32 bound a loop with no cancellation point
const std = @import("std");
pub fn f(io: std.Io, r: *std.Io.Reader, out: *u64) !void {
    _ = io;
    const n: u32 = @bitCast((try r.takeArray(4)).*);
    var i: u32 = 0;
    while (i < n) : (i += 1) out.* +%= i;
}
