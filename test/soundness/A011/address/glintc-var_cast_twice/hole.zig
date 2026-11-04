// A raw count written into std's Duration through a var given a pointer cast to its integer on
// each path.
const std = @import("std");
pub fn f(ns: i96, early: bool) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    var raw: *i96 = @ptrCast(&d);
    if (early) raw = @ptrCast(&d);
    raw.* = ns;
    return d;
}
