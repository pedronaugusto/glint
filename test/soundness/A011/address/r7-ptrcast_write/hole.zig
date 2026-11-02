// A raw count written into std's Duration through a pointer cast to its integer.
const std = @import("std");
pub fn f(ns: i96) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    const raw: *i96 = @ptrCast(&d);
    raw.* = ns;
    return d;
}
