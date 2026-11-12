// A015: a pipe pair, two files held by value in an array (review 8, M7).
const aegis = @import("aegis");
const std = @import("std");
pub const Pipe = struct { ends: [2]std.Io.File };
