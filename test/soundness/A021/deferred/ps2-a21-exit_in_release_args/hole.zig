// A `try` in the release's own argument leaves before the release runs, a still held; the deferred b is then
// taken while a is held.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.BlockingGuarded(u32);
const Session = struct {
    io: ?std.Io,
    fn ioOf(s: *const Session) !std.Io {
        return s.io orelse error.Closed;
    }
};
pub fn both(a: *L, b: *L, s: *const Session, io: std.Io) !void {
    defer {
        var h = b.acquireUncancelable(io);
        h.deinit(io);
    }
    var g = a.acquireUncancelable(io);
    g.deinit(try s.ioOf());
}
