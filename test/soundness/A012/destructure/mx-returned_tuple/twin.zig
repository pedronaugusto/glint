// matrix: the part destructured from a helper's returned tuple, checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
fn header(r: *std.Io.Reader) !struct { u32, u8 } {
    return .{ try r.takeInt(u32, .little), 1 };
}
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const len, const kind = try header(r);
    _ = kind;
    try limit.check(len);
    return gpa.alloc(u8, len);
}
