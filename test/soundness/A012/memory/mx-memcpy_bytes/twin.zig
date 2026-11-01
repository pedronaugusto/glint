// matrix: a peer's four bytes copied by @memcpy into the size's own bytes, checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 0;
    @memcpy(std.mem.asBytes(&n), try r.take(4));
    try limit.check(n);
    return gpa.alloc(u8, n);
}
