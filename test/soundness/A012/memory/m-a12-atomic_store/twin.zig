// matrix A012 memory: the atomic store moves a limited size
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 0;
    const m = try r.takeInt(u32, .little);
    if (m > 4096) return error.TooLarge;
    @atomicStore(u32, &n, m, .monotonic);
    return gpa.alloc(u8, @atomicLoad(u32, &n, .monotonic));
}
