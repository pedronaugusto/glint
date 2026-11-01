// matrix A012 memory: input moved through an atomic store and load
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 0;
    @atomicStore(u32, &n, try r.takeInt(u32, .little), .monotonic);
    return gpa.alloc(u8, @atomicLoad(u32, &n, .monotonic));
}
