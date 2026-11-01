// review 5: c/c05_ptrcast_read.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const bytes = try r.takeArray(8);
    const p: *align(1) const u64 = @ptrCast(bytes);
    return p.* * 2;
}
