const std = @import("std");
const aegis = @import("aegis");
// A dependency that makes a lock and hands it out by value, and one that hands out aegis's.
pub fn make() std.Io.Mutex {
    return .init;
}
pub fn guarded() aegis.BlockingGuarded(u32) {
    return .init(0);
}
pub var global: std.Io.Mutex = .init;
