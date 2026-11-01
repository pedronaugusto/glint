// matrix: input put into a tuple literal, its element checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const t = .{ @as(u32, 8), try r.takeInt(u32, .little) };
    try limit.check(t[1]);
    return gpa.alloc(u8, t[1]);
}
