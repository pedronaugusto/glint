const std = @import("std");
const aegis = @import("aegis");
pub fn pair() struct { std.Io.Mutex, u32 } {
    return .{ .init, 1 };
}
pub fn guardedPair() struct { aegis.BlockingGuarded(u32), u32 } {
    return .{ .init(0), 1 };
}
