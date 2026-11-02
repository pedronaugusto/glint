// A Duration written through a pointer to it.
const std = @import("std");
pub fn f(src: std.Io.Duration) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    const p: *std.Io.Duration = &d;
    p.* = src;
    return d;
}
