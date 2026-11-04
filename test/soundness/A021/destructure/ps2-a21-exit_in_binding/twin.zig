// The byte is read before a is taken: no exit leaves a held.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L, r: *std.Io.Reader) !u8 {
    defer {
        var h = b.acquire();
        h.deinit();
    }
    const byte = try r.takeByte();
    var g, const n = .{ a.acquire(), byte };
    g.deinit();
    return n;
}
