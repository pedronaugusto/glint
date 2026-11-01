// warp-fast: an array field holds pointers to locks: borrows.
const std = @import("std");
pub const Shards = struct { locks: [4]*std.Io.Mutex };
