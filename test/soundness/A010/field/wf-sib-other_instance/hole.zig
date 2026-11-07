// wf A010 field sibling: two instances: one cursor's end less another's position, which no relation ties
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
    var a = Cursor.init(bytes);
    var b = Cursor.init(bytes[0..1]);
    a.advance(n);
    b.advance(n);
    return b.end - a.pos;
}
