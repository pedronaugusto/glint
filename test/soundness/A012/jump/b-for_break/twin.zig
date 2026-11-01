// matrix A012 jump: a for breaks with input, its value checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n: u32 = for (0..3) |_| {
        const v = try r.takeInt(u32, .little);
        if (v != 0) break v;
    } else 16;
    try limit.check(n);
    return gpa.alloc(u8, n);
}
