const std = @import("std");
// A dependency's generic record, made over a raw lock and over a plain number.
pub fn Box(comptime T: type) type {
    return struct { value: T, tag: u8 = 0 };
}
pub const Locked = Box(std.Io.Mutex);
pub const Counted = Box(u32);
