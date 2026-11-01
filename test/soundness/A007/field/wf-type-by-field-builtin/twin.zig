// warp-fast: @field names a std type that synchronizes nothing.
const std = @import("std");
const Stamp = @field(std.Io, "Timestamp");
pub const Shared = struct { at: Stamp, n: u32 = 0 };
