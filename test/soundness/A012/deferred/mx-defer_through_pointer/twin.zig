// matrix: a defer writes input through a pointer to the size, checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 64;
    const m = try r.takeInt(u32, .little);
    {
        const p = &n;
        defer p.* = m;
    }
    try limit.check(n);
    return gpa.alloc(u8, n);
}
