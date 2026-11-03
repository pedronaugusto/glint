const std = @import("std");
fn copy(d: []u8, s: []const u8) void {
    std.mem.copyForwards(u8, d, s);
}
pub fn f(ns: i96) i96 {
    var d: i96 = 0;
    copy(std.mem.asBytes(&d), std.mem.asBytes(&ns));
    return d;
}
