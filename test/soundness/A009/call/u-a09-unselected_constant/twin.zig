// matrix A009 call: the same function given a constant, the program holding no input where that file may read it beside its parameters: what it meets is its package's own
const std = @import("std");
const w = @import("w.zig");
pub fn f(r: *std.Io.Reader) !u64 {
    _ = try r.takeByte();
    return w.spin(3);
}
