// review 4: rt/w_base.zig
const std = @import("std");
fn setValue(out: *u32, r: *std.Io.Reader) !void {
    out.* = try r.takeInt(u32, .little);
}
pub fn f(r: *std.Io.Reader) !u32 {
    var x: u32 = 0;
    try setValue(&x, r);
    return x + 1;
}
