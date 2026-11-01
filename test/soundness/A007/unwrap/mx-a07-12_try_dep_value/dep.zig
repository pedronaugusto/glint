const std = @import("std");
const aegis = @import("aegis");
pub fn tryMake(ok: bool) !std.Io.Mutex {
    if (!ok) return error.Refused;
    return .init;
}
pub fn tryGuarded(ok: bool) !aegis.BlockingGuarded(u32) {
    if (!ok) return error.Refused;
    return .init(0);
}
