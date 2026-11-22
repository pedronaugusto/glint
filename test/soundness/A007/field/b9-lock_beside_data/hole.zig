// A007: a field holding std's lock apart from the data it guards: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub const Counter = struct { lock: std.Io.Mutex = .init, count: u32 = 0 };
