// A015: std's file type reached through a pointer to it, held by value in a field: a finding.
const aegis = @import("aegis");
const std = @import("std");
const F = &std.Io.File;
pub const Log = struct { file: F.* };
