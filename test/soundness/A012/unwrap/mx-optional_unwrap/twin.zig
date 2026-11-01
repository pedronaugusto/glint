// matrix: an optional holding input unwrapped by .?, checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var maybe: ?u32 = null;
    maybe = try r.takeInt(u32, .little);
    try limit.check(maybe.?);
    return gpa.alloc(u8, maybe.?);
}
