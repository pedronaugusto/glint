// matrix A009 call: the variable given a constant before the call
const std = @import("std");
const w = @import("w.zig");
pub fn f(r: *std.Io.Reader) !u8 {
    w.at = 1;
    const n = w.pick(0);
    _ = try r.takeByte();
    return n;
}
