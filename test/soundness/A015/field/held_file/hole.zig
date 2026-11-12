// A015: a std file held by value in a field is an owner nothing checks.
const aegis = @import("aegis");
const std = @import("std");
pub const Log = struct { file: std.Io.File };
