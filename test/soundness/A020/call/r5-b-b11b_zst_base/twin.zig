// review 5: b/b11b_zst_base.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const n: usize = try r.takeInt(u64, .little);
    return n + 1;
}
