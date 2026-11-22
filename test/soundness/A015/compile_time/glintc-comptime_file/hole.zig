// A015: std's file type a comptime expression's value, held by value in a field: a finding.
const aegis = @import("aegis");
const std = @import("std");
fn Make() type {
    const F = comptime std.Io.File;
    return struct { file: F };
}
pub const Log = Make();
