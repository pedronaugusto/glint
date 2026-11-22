// A015: a file borrowed by pointer in a tuple's field.
const aegis = @import("aegis");
const std = @import("std");
pub const Pair = struct { *const std.Io.File, u8 };
