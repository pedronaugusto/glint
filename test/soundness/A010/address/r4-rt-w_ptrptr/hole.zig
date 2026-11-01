// review 4: rt/w_ptrptr.zig
const std = @import("std");
fn setValue(out: **u32, r: *std.Io.Reader) !void {
    out.*.* = try r.takeInt(u32, .little);
}
pub fn f(r: *std.Io.Reader) !u32 {
    var x: u32 = 0;
    var p: *u32 = &x;
    try setValue(&p, r);
    return x + 1;
}
