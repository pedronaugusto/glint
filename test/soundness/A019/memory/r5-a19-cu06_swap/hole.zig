// review 5: a19/cu06_swap.zig
const std = @import("std");
const Writer = struct {
    bytes: []u8,
    pos: usize = 0,
    fn put(self: *Writer, b: []const u8) error{Full}!void {
        if (b.len > self.bytes.len - self.pos) return error.Full;
        @memcpy(self.bytes[self.pos..][0..b.len], b);
        self.pos += b.len;
    }
};
fn use(b: []const u8) void {
    _ = b;
}
pub fn run() !void {
    var buf: [16]u8 = undefined;
    var other: [16]u8 = undefined;
    var w: Writer = .{ .bytes = &buf };
    var v: Writer = .{ .bytes = &other };
    try v.put("abcd");
    std.mem.swap(Writer, &w, &v);
    use(buf[0..w.pos]);
    use(other[0..v.pos]);
}
