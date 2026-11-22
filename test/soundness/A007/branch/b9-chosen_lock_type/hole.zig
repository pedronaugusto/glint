// A007: a lock chosen by an if, std's either way, held by a field apart from the data: a finding.
const aegis = @import("aegis");
const std = @import("std");
const shared = false;
const Lock = if (shared) std.Io.RwLock else std.Io.Mutex;
pub const Counter = struct { lock: Lock = .init, count: u32 = 0 };
