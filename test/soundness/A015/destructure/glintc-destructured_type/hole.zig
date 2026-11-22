// A015: std's file type named by a destructure, held by value in a field: a finding.
const aegis = @import("aegis");
const std = @import("std");
fn Make() type {
    const F, _ = .{ std.Io.File, u8 };
    return struct { file: F };
}
pub const Log = Make();
