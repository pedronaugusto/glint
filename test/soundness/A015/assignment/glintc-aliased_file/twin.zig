// A015: std's file type held by a const, borrowed by pointer in a field: none.
const aegis = @import("aegis");
const std = @import("std");
const F = std.Io.File;
pub const Log = struct { file: *F };
