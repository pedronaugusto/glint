// The chosen guard released.
const std = @import("std");
const aegis = @import("aegis");
const RW = aegis.RwGuarded(u32);
fn lock(comptime shared: bool, l: *RW, io: std.Io) !(if (shared) RW.ReadGuard else RW.WriteGuard) {
    return if (shared) l.read(io) else l.write(io);
}
pub fn f(l: *RW, io: std.Io) !u32 {
    var g = try lock(true, l, io);
    defer g.deinit(io);
    return g.value().*;
}
