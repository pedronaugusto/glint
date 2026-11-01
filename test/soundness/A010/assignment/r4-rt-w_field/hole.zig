// review 4: rt/w_field.zig
const std = @import("std");
const H = struct { p: *u32 };
fn setValue(out: *u32, r: *std.Io.Reader) !void {
    out.* = try r.takeInt(u32, .little);
}
pub fn f(r: *std.Io.Reader) !u32 {
    var x: u32 = 0;
    const h: H = .{ .p = &x };
    try setValue(h.p, r);
    return x + 1;
}
