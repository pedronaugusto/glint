// review 5: c/c01_bytes_to_value.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const bytes = try r.takeArray(8);
    const x = std.mem.bytesToValue(u64, bytes);
    return x * 2;
}
