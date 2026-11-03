// warp-fast: another file's type, lent the directory its field holds
const std = @import("std");
pub const S = struct { d: std.Io.Dir, n: u32 };
