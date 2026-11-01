// review 5: a19/cu01_step_other_receiver.zig
const Writer = struct {
    bytes: []u8,
    pos: usize = 0,
    fn put(self: *Writer, b: []const u8) error{Full}!void {
        if (b.len > self.bytes.len - self.pos) return error.Full;
        @memcpy(self.bytes[self.pos..][0..b.len], b);
        self.pos += b.len;
    }
    fn skip(self: *Writer, other: *Writer, b: []const u8) void {
        @memcpy(other.bytes[other.pos..][0..b.len], b);
        self.pos += b.len;
    }
};
fn use(b: []const u8) void {
    _ = b;
}
pub fn run() !void {
    var buf: [16]u8 = undefined;
    var w: Writer = .{ .bytes = &buf };
    try w.put("ab");
    var v: Writer = .{ .bytes = &buf };
    w.skip(&v, "cd");
    use(buf[0..w.pos]);
}
