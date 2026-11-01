// matrix: std's alloc called through @call with a size checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u32, .little);
    try limit.check(n);
    return @call(.auto, std.mem.Allocator.alloc, .{ gpa, u8, n });
}
