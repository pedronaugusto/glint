// review 6: b/k11_slice_set_in_callee.zig
const std = @import("std");
fn shrink(p: *[]u8) void {
    p.* = p.*[0..1];
}
// A callee given the slice's address shortens it.
pub fn f(r: *std.Io.Reader) !u8 {
    var memory: [512]u8 = @splat(0);
    var s: []u8 = memory[0..];
    shrink(&s);
    const i: usize = try r.takeInt(u16, .little);
    if (i >= 512) return 0;
    return s[i];
}
