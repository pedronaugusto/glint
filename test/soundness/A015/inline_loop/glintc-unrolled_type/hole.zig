// A015: std's file type an unrolled loop's capture, held by value in a field: a finding.
const aegis = @import("aegis");
const std = @import("std");
fn Make() type {
    comptime var T: type = void;
    inline for (.{std.Io.File}) |F| T = F;
    return struct { file: T };
}
pub const Log = Make();
