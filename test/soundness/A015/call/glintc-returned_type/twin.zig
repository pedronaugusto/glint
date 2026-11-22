// A015: std's file type a function's result, borrowed by pointer in a field: none.
const aegis = @import("aegis");
const std = @import("std");
fn Handle() type {
    return std.Io.File;
}
pub const Log = struct { file: *Handle() };
