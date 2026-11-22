// A015: std's file type captured from an optional, borrowed by pointer in a field: none.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = std.Io.File;
fn Make() type {
    if (held) |F| return struct { file: *F };
    return struct {};
}
pub const Log = Make();
