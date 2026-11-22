// A015: std's file type an element of a tuple of types, held by value in a field: a finding.
const aegis = @import("aegis");
const std = @import("std");
const kinds = .{std.Io.File};
pub const Log = struct { file: kinds[0] };
