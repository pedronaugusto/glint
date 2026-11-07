// wf A010 field sibling: the buffer shrunk under the end: taken to input's length, which leaves the end past it
const std = @import("std");
const Cursor = struct {
    buf: []const u8,
    pos: usize = 0,
    end: usize = 0,
    fn init(buf: []const u8) Cursor {
        return .{ .buf = buf, .end = buf.len };
    }
    fn advance(c: *Cursor, n: usize) void {
        if (n > c.end - c.pos) return;
        c.pos += n;
    }
};
pub fn f(r: *std.Io.Reader) !usize {
    const bytes = try r.take(64);
    const n: usize = try r.takeInt(u32, .little);
    var c = Cursor.init(bytes);
    c.advance(4);
    if (n > bytes.len) return error.Long;
    c.buf = c.buf[0..n];
    return c.buf.len - c.end;
}
