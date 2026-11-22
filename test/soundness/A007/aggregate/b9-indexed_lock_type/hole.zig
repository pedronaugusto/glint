// A007: std's lock an element of a tuple, held by a field apart from the data: a finding.
const aegis = @import("aegis");
const std = @import("std");
const locks = .{std.Io.Mutex};
pub const Counter = struct { lock: locks[0] = .init, count: u32 = 0 };
