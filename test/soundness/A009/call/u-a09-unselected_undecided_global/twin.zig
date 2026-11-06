// matrix A009 call: the variable given a constant before the call
const std = @import("std");
const w = @import("w.zig");
pub fn f(r: *std.Io.Reader) !u64 {
    w.limit = 3;
    const n = w.spin(3);
    _ = try r.takeByte();
    return n;
}
