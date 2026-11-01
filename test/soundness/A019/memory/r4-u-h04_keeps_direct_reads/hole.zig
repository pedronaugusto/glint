// review 4: u/h04_keeps_direct_reads.zig
// held? keeps followed by a direct read of the kept buffer (expected: one finding each)
const std = @import("std");
pub fn k1(v: u32) !u8 {
    var buf: [16]u8 = undefined;
    _ = try std.fmt.bufPrint(&buf, "{d}", .{v});
    return buf[15];
}
pub fn k2() !u8 {
    var buf: [64]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const s = try fba.allocator().alloc(u8, 4);
    @memset(s, 0);
    return buf[63];
}
pub fn k3(in: []const u8) u8 {
    var buf: [16]u8 = undefined;
    _ = std.ascii.lowerString(&buf, in[0..@min(in.len, 4)]);
    return buf[15];
}
pub fn k4(r: *std.Io.Reader) !u8 {
    var buf: [16]u8 = undefined;
    const n = try r.readSliceShort(&buf);
    _ = n;
    return buf[15];
}
pub fn k5(r: *std.Io.Reader) !u8 {
    var buf: [16]u8 = undefined;
    const n = try r.readSliceShort(&buf);
    if (n == 0) return 0;
    return buf[n - 1] +% buf[15];
}
