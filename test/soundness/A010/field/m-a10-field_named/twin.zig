// matrix A010 field: @field names the constant part beside the input
const std = @import("std");
const V = struct { v: u64, k: u64 };
pub fn f(r: *std.Io.Reader) !u64 {
    const h: V = .{ .v = try r.takeInt(u64, .little), .k = 3 };
    return @field(h, "k") * 1000;
}
