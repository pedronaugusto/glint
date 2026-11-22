// A007: std's lock converted to a type by @as, held by a field apart from the data: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub const Counter = struct { lock: @as(type, std.Io.Mutex) = .init, count: u32 = 0 };
