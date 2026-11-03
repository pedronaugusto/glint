// A raw count stored into std's Duration by the program's setter, handed the Duration through a pointer cast.
const std = @import("std");
fn set(raw: *i96, ns: i96) void {
    raw.* = ns;
}
pub fn f(ns: i96) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    set(@ptrCast(&d), ns);
    return d;
}
