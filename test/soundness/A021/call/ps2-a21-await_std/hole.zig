// A guard std hands back: io.async runs L.acquire and Future(L.Guard).await gives its guard, held while b is taken.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L, io: std.Io) void {
    var fa = io.async(L.acquire, .{a});
    var ga = fa.await(io);
    defer ga.deinit();
    var gb = b.acquire();
    defer gb.deinit();
}
