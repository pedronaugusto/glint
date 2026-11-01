// review 6: a15/o03_identity_call.zig
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
// A function that hands back what it is given hands back the owner it is given.
fn pass(f: std.Io.File) std.Io.File {
    return f;
}
pub fn store(s: *Stored, dir: std.Io.Dir, io: std.Io) !void {
    s.file = pass(try dir.openFile(io, "a", .{}));
}
