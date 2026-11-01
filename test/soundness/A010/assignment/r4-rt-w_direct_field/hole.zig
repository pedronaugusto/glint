// review 4: rt/w_direct_field.zig
const std = @import("std");
const H = struct { p: *u32 };
pub fn f(r: *std.Io.Reader) !u32 {
    var x: u32 = 0;
    const h: H = .{ .p = &x };
    h.p.* = try r.takeInt(u32, .little);
    return x + 1;
}
