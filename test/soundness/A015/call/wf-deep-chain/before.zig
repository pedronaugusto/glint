// warp-fast: another file's type, lent the file its field holds
const std = @import("std");
pub const S = struct { f: std.Io.File, n: u32 };
