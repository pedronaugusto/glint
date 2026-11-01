// review 5: b/b20b_a020_base.zig
const std = @import("std");
pub fn f(io: std.Io, r: *std.Io.Reader, out: *u8) !void {
    _ = io;
    const n: usize = try r.takeInt(u32, .little);
    var i: usize = 0;
    while (i < n) : (i += 1) out.* +%= 1;
}
