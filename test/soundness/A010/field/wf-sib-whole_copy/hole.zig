// wf A010 field sibling: a whole value copied in from an instance a literal broke: every instance's relation is refused
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
    const o: Cursor = .{ .buf = bytes, .pos = n, .end = 0 };
    c = o;
    return c.end - c.pos;
}
