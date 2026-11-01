// review 5: a20/c15_ptr_capture_payload.zig
const std = @import("std");
pub fn count(io: std.Io, r: *std.Io.Reader) !u64 {
    _ = io;
    const seed = try r.takeInt(u32, .little);
    var left: ?u32 = 5;
    var total: u64 = 0;
    if (left) |*p| p.* = seed;
    while (left) |n| {
        total +%= n;
        left = if (n == 0) null else n - 1;
    }
    return total;
}
