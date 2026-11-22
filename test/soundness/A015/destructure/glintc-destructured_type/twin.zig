// A015: std's file type named by a destructure, borrowed by pointer in a field: none.
const aegis = @import("aegis");
const std = @import("std");
fn Make() type {
    const F, _ = .{ std.Io.File, u8 };
    return struct { file: *F };
}
pub const Log = Make();
