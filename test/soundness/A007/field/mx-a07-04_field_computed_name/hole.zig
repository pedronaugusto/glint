// matrix A007: a field whose type @field names with a computed name is std's Mutex.
const std = @import("std");
pub const Shared = struct {
    lock: @field(std.Io, "Mu" ++ "tex") = .init,
    count: u32 = 0,
};
