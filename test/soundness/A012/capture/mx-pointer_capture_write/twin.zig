// matrix: input written through a for loop's pointer capture, the element checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var sizes: [2]u32 = .{ 0, 0 };
    for (&sizes) |*s| s.* = try r.takeInt(u32, .little);
    try limit.check(sizes[0]);
    return gpa.alloc(u8, sizes[0]);
}
