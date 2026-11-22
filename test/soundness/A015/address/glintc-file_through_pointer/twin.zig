// A015: std's file type reached through a pointer to it, borrowed by pointer in a field: none.
const aegis = @import("aegis");
const std = @import("std");
const F = &std.Io.File;
pub const Log = struct { file: *F.* };
