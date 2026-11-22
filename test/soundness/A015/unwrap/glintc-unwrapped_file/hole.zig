// A015: std's file type unwrapped from an optional by .?, held by value in a field: a finding.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = std.Io.File;
pub const Log = struct { file: held.? };
