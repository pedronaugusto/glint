// review 4: rt/w_slicevec.zig
const std = @import("std");
fn setAll(outs: []const *u32, r: *std.Io.Reader) !void {
    for (outs) |o| o.* = try r.takeInt(u32, .little);
}
pub fn f(r: *std.Io.Reader) !u32 {
    var x: u32 = 0;
    try setAll(&.{&x}, r);
    return x + 1;
}
