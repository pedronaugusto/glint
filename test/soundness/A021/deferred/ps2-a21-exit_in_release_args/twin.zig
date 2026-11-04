// The Io is found before a is taken: no exit leaves a held.
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
    const own = try s.ioOf();
    var g = a.acquireUncancelable(io);
    g.deinit(own);
}
