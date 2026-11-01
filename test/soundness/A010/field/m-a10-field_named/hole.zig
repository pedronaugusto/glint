// matrix A010 field: @field names the part holding input, multiplied past its type
const std = @import("std");
const V = struct { v: u64, k: u64 };
pub fn f(r: *std.Io.Reader) !u64 {
    const h: V = .{ .v = try r.takeInt(u64, .little), .k = 3 };
    return @field(h, "v") * 1000;
}
