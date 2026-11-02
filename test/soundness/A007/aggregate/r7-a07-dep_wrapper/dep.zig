const std = @import("std");
const aegis = @import("aegis");
// A dependency's record that holds a raw mutex by value, and one that holds its count under aegis's Guarded.
pub const Shared = struct { lock: std.Io.Mutex = .init, count: u32 = 0 };
pub const Safe = struct { count: aegis.Guarded(u32) = .init(0) };
