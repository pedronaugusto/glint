// warp-fast: @field names std's lock type by a literal name; a field holds it by value.
const std = @import("std");
const Lock = @field(std.Io, "Mutex");
pub const Shared = struct { lock: Lock = .init, n: u32 = 0 };
