// review 4: rt/w_holder.zig
const std = @import("std");
const H = struct { p: *u32 };
fn set(h: H, r: *std.Io.Reader) !void {
    h.p.* = try r.takeInt(u32, .little);
}
pub fn f(r: *std.Io.Reader) !u32 {
    var x: u32 = 0;
    try set(.{ .p = &x }, r);
    return x + 1;
}
