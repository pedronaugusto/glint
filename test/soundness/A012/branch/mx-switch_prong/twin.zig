// matrix: a switch expression gives input in one prong, checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, kind: enum { small, sized }) ![]u8 {
    const n: u32 = switch (kind) {
        .small => 16,
        .sized => try r.takeInt(u32, .little),
    };
    try limit.check(n);
    return gpa.alloc(u8, n);
}
