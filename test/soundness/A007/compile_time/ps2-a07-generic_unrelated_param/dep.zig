const std = @import("std");
// A dependency's array of one lock, and of one counter.
pub const Locks = [1]std.Io.Mutex;
pub const Counts = [1]u32;
