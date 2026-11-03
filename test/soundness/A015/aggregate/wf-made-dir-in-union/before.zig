// warp-fast: another file's type, lent the directory its field holds, and a parent kept as a union
const std = @import("std");
pub const S = struct { d: std.Io.Dir, n: u32 };
pub const Parent = union(enum) { owned: std.Io.Dir, lent: std.Io.Dir };
