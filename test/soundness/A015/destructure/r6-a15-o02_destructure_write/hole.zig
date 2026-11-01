// review 6: a15/o02_destructure_write.zig
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
// A destructure writes the field too.
pub fn store(s: *Stored, dir: std.Io.Dir, io: std.Io) !void {
    s.file, s.n = .{ try dir.openFile(io, "a", .{}), 1 };
}
