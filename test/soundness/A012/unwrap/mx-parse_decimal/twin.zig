// matrix: a size a peer writes in decimal, parsed by std, checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const text = try r.takeDelimiterExclusive('\n');
    const n = try std.fmt.parseInt(u32, text, 10);
    try limit.check(n);
    return gpa.alloc(u8, n);
}
