// A015: std's file type an element of a tuple of types, borrowed by pointer in a field: none.
const aegis = @import("aegis");
const std = @import("std");
const kinds = .{std.Io.File};
pub const Log = struct { file: *kinds[0] };
