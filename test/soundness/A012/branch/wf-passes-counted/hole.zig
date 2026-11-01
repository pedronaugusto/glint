// warp-fast: a size counted by the passes of a loop a peer's bytes decide: the peer chooses how much it allocates
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 0;
    while (try r.takeByte() != 0) n += 1;
    return gpa.alloc(u8, n);
}
