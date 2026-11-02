// A guard whose type a comptime argument chooses (a read or a write guard) is never released.
const std = @import("std");
const aegis = @import("aegis");
const RW = aegis.RwGuarded(u32);
fn lock(comptime shared: bool, l: *RW, io: std.Io) !(if (shared) RW.ReadGuard else RW.WriteGuard) {
    return if (shared) l.read(io) else l.write(io);
}
pub fn f(l: *RW, io: std.Io) !u32 {
    const g = try lock(true, l, io);
    return g.value().*;
}
