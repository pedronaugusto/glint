// A015: std's file type converted to a type by @as, borrowed by pointer in a field: none.
const aegis = @import("aegis");
const std = @import("std");
pub const Log = struct { file: *@as(type, std.Io.File) };
