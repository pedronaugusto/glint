// A015: std's file type a labeled block's result, borrowed by pointer in a field: none.
const aegis = @import("aegis");
const std = @import("std");
const F = blk: {
    break :blk std.Io.File;
};
pub const Log = struct { file: *F };
