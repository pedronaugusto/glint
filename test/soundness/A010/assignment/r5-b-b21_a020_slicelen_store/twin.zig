// review 5: b/b21_a020_slicelen_store.zig
const std = @import("std");
pub fn f(io: std.Io, r: *std.Io.Reader, out: *u8) !void {
    _ = io;
    var memory: [16]u8 = @splat(0);
    var s: []u8 = memory[0..];
    const n: usize = try r.takeInt(u32, .little);
    s.len = n;
    var i: usize = 0;
    while (i < s.len) : (i += 1) out.* +%= 1;
}
