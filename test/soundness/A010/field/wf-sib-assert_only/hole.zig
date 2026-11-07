// wf A010 field sibling: a std.debug.assert as the only check: undefined behaviour in a release build when false, so no check
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
fn skip(c: *Cursor, n: usize) void {
    std.debug.assert(n <= c.end - c.pos);
    c.pos += n;
}
pub fn f(r: *std.Io.Reader) !usize {
    const bytes = try r.take(64);
    const n: usize = try r.takeInt(u32, .little);
    var c = Cursor.init(bytes);
    skip(&c, n);
    return c.end - c.pos;
}
