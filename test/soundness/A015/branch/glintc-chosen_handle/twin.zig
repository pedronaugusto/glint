// A015: std's file type chosen by an if (a directory or a file), borrowed by pointer in a field: none.
const aegis = @import("aegis");
const std = @import("std");
const wide = false;
const F = if (wide) std.Io.Dir else std.Io.File;
pub const Log = struct { file: *F };
