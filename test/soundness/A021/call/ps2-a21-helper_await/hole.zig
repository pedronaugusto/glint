// The program's helper returns the guard std's Future.await gives it: b is taken while a is held.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lockOf(a: *L, io: std.Io) L.Guard {
    var f = io.async(L.acquire, .{a});
    return f.await(io);
}
pub fn both(a: *L, b: *L, io: std.Io) void {
    var ga = lockOf(a, io);
    defer ga.deinit();
    var gb = b.acquire();
    defer gb.deinit();
}
