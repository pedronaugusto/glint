// matrix A010 aggregate: a struct literal holds input, read back and multiplied
const std = @import("std");
const V = struct { v: u64, k: u64 };
pub fn f(r: *std.Io.Reader) !u64 {
    const h: V = .{ .v = try r.takeInt(u64, .little), .k = 3 };
    return h.v * 1000;
}
