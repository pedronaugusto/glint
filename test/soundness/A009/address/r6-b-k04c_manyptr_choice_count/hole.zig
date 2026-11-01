// review 6: b/k04c_manyptr_choice_count.zig
const std = @import("std");
pub fn f(io: std.Io, r: *std.Io.Reader, p: [*]const u8, p2: [*]const u8, c: bool, out: *u8) !void {
    _ = io;
    const n: usize = try r.takeInt(u32, .little);
    const q = if (c) p else p2;
    const s = q[0..n];
    var i: usize = 0;
    while (i < s.len) : (i += 1) out.* +%= s[i];
}
