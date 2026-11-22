// A015: a file held by value in a tuple's field.
const aegis = @import("aegis");
const std = @import("std");
pub const Pair = struct { std.Io.File, u8 };
