const std = @import("std");
fn set(raw: *i96, ns: i96) void {
    raw.* = ns;
}
pub fn f(ns: i96) i96 {
    var d: i96 = 0;
    set(@ptrCast(&d), ns);
    return d;
}
