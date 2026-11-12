// A015: a field that borrows the file by pointer holds no owner.
const aegis = @import("aegis");
const std = @import("std");
pub const Log = struct { file: *std.Io.File };
