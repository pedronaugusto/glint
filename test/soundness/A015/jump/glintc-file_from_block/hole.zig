// A015: std's file type a labeled block's result, held by value in a field: a finding.
const aegis = @import("aegis");
const std = @import("std");
const F = blk: {
    break :blk std.Io.File;
};
pub const Log = struct { file: F };
