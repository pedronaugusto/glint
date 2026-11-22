// A015: std's file type a comptime expression's value, borrowed by pointer in a field: none.
const aegis = @import("aegis");
const std = @import("std");
fn Make() type {
    const F = comptime std.Io.File;
    return struct { file: *F };
}
pub const Log = Make();
