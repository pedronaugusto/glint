// review 5: b/b13f_destructure_loop_twin.zig
const std = @import("std");
pub fn f(io: std.Io, r: *std.Io.Reader, out: *u8) !void {
    _ = io;
    var n: usize = 5;
    n = try r.takeInt(u32, .little);
    var i: usize = 0;
    while (i < n) : (i += 1) out.* +%= 1;
}
