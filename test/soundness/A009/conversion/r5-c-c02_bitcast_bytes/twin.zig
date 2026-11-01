// review 5: c/c02_bitcast_bytes.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const bytes = try r.takeArray(8);
    const x: u64 = @bitCast(bytes.*);
    return x * 2;
}
