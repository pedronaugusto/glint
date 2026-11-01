// review 6: b/k04b_manyptr_direct_count.zig
const std = @import("std");
pub fn f(io: std.Io, r: *std.Io.Reader, p: [*]const u8, out: *u8) !void {
    _ = io;
    const n: usize = try r.takeInt(u32, .little);
    const s = p[0..n];
    var i: usize = 0;
    while (i < s.len) : (i += 1) out.* +%= s[i];
}
