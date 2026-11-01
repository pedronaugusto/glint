// review 6: a15/o00_assign_base.zig
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
// Twin: an opened file written into the field by `=` is an owner held by hand.
pub fn store(s: *Stored, dir: std.Io.Dir, io: std.Io) !void {
    s.file = try dir.openFile(io, "a", .{});
}
