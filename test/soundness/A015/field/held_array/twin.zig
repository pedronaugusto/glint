// A015: an array of borrowed files holds no owner.
const aegis = @import("aegis");
const std = @import("std");
pub const Pipe = struct { ends: [2]*std.Io.File };
