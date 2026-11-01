// review 4: rt/w_global.zig
const std = @import("std");
var target: *u32 = undefined;
fn set(r: *std.Io.Reader) !void {
    target.* = try r.takeInt(u32, .little);
}
pub fn f(r: *std.Io.Reader) !u32 {
    var x: u32 = 0;
    target = &x;
    try set(r);
    return x + 1;
}
