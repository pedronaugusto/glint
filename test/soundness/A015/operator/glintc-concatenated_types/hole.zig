// A015: std's file type an element of tuples joined by ++, held by value in a field: a finding.
const aegis = @import("aegis");
const std = @import("std");
const both = .{u8} ++ .{std.Io.File};
pub const Log = struct { file: both[1] };
