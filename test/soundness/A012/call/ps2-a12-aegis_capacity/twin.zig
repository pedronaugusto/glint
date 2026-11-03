// aegis's SecretBytes allocates a capacity a peer chose, checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !aegis.secret.SecretBytes {
    const n = try r.takeInt(u32, .little);
    try limit.check(n);
    return aegis.secret.SecretBytes.init(gpa, n);
}
