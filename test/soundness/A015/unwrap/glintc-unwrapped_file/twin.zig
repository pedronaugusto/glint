// A015: std's file type unwrapped from an optional by .?, borrowed by pointer in a field: none.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = std.Io.File;
pub const Log = struct { file: *held.? };
