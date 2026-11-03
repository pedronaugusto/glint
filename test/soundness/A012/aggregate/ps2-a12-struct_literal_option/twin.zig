// std's process.run reserving a size a peer chose, checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, io: std.Io) !std.process.RunResult {
    const n = try r.takeInt(u32, .little);
    try limit.check(n);
    return std.process.run(gpa, io, .{ .argv = &.{"true"}, .reserve_amount = n });
}
