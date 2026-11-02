const std = @import("std");
// A dependency that makes a raw lock, and a number.
pub fn make() std.Io.Mutex {
    return .init;
}
pub fn count() u32 {
    return 0;
}
