// review 6: b/k04_manyptr_arith_count.zig
const std = @import("std");
// A many-item pointer moved by arithmetic, then sliced: the slice's length is the program's word, not memory held.
pub fn f(io: std.Io, r: *std.Io.Reader, p: [*]const u8, out: *u8) !void {
    _ = io;
    const n: usize = try r.takeInt(u32, .little);
    const q = p + 1;
    const s = q[0..n];
    var i: usize = 0;
    while (i < s.len) : (i += 1) out.* +%= s[i];
}
