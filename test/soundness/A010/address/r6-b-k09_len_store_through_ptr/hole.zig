// review 6: b/k09_len_store_through_ptr.zig
const std = @import("std");
// The slice's length set through a pointer to it: s.len is n afterwards.
pub fn f(r: *std.Io.Reader) !usize {
    var memory: [512]u8 = @splat(0);
    var s: []u8 = memory[0..];
    const n: usize = try r.takeInt(u64, .little);
    const q = &s;
    q.len = n;
    return s.len - 86;
}
