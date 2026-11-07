// wf A010 field sibling: a whole value copied in from an instance made by init: the relation holds of every instance
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
    var o = Cursor.init(bytes);
    o.advance(n);
    c = o;
    return c.end - c.pos;
}
