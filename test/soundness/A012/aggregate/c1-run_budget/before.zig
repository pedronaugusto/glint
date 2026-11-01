// c1: a program's other file, read first: it spends this file's fact budget inside the answers
// the run keeps for every file (std's reader and the allocations input sizes)
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const t = .{ @as(u32, 8), try r.takeInt(u32, .little) };
    return gpa.alloc(u8, t[1]);
}
