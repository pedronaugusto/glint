// A015: std's file type an element of tuples joined by ++, borrowed by pointer in a field: none.
const aegis = @import("aegis");
const std = @import("std");
const both = .{u8} ++ .{std.Io.File};
pub const Log = struct { file: *both[1] };
