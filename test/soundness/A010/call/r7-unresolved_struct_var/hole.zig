// A010: a callback that does not resolve is given a struct variable holding a pointer: it may write the peer's number there, which then overflows
const std = @import("std");
const Out = struct { n: *u64, r: *std.Io.Reader };
pub fn f(r: *std.Io.Reader, cb: *const fn (Out) anyerror!void) !u64 {
    var n: u64 = 0;
    const out: Out = .{ .n = &n, .r = r };
    try cb(out);
    return n * 3;
}
