// matrix A007: the same field as a borrow of a lock held elsewhere.
const std = @import("std");
pub const Shared = struct {
    lock: *@field(std.Io, "Mu" ++ "tex"),
    count: u32 = 0,
};
