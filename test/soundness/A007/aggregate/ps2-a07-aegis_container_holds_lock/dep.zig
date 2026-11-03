const std = @import("std");
// A dependency's record holding a lock by value, and one holding a counter.
pub const Shared = struct { lock: std.Io.Mutex = .init, n: u32 = 0 };
pub const Plain = struct { n: u32 = 0 };
