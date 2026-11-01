// matrix A012 unwrap: an optional of constants, chosen by input, unwrapped with orelse
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const maybe: ?u32 = if (try r.takeByte() == 0) null else 64;
    const n = maybe orelse 16;
    return gpa.alloc(u8, n);
}
