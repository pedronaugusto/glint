// A raw count stored into std's Durations an allocator gives, through a view of them as integers.
const std = @import("std");
pub fn f(a: std.mem.Allocator, ns: i96) ![]std.Io.Duration {
    const out = try a.alloc(std.Io.Duration, 1);
    const raw: []i96 = @ptrCast(out);
    raw[0] = ns;
    return out;
}
