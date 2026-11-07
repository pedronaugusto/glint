// wf A010 field sibling: made undefined and then field by field: no relation until both sides are written, so none
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
    var c: Cursor = undefined;
    c.buf = bytes;
    c.pos = n;
    c.end = bytes.len;
    return c.end - c.pos;
}
