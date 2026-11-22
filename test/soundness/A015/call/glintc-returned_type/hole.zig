// A015: std's file type a function's result, held by value in a field: a finding.
const aegis = @import("aegis");
const std = @import("std");
fn Handle() type {
    return std.Io.File;
}
pub const Log = struct { file: Handle() };
