// A015: std's file type converted to a type by @as, held by value in a field: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub const Log = struct { file: @as(type, std.Io.File) };
