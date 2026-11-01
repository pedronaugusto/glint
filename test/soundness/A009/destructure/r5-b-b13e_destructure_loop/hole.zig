// review 5: b/b13e_destructure_loop.zig
const std = @import("std");
pub fn f(io: std.Io, r: *std.Io.Reader, out: *u8) !void {
    _ = io;
    var n: usize = 5;
    n, _ = .{ try r.takeInt(u32, .little), 0 };
    var i: usize = 0;
    while (i < n) : (i += 1) out.* +%= 1;
}
