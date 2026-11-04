// A `try` in the statement that binds the guard, after the acquisition, leaves with a held: the deferred b is then
// taken while a is held.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L, r: *std.Io.Reader) !u8 {
    defer {
        var h = b.acquire();
        h.deinit();
    }
    var g, const n = .{ a.acquire(), try r.takeByte() };
    g.deinit();
    return n;
}
