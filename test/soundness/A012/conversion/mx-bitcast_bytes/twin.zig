// matrix: a peer's four bytes made a size by @bitCast, checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const bytes = try r.takeArray(4);
    const n: u32 = @bitCast(bytes.*);
    try limit.check(n);
    return gpa.alloc(u8, n);
}
