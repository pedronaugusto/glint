// review 6: a15/o04_capture_ptr_write.zig
const std = @import("std");
const Stored = struct { file: ?std.Io.File, n: u32 };
// Written through a pointer capture of the field.
pub fn store(s: *Stored, dir: std.Io.Dir, io: std.Io) !void {
    if (s.file) |*p| p.* = try dir.openFile(io, "a", .{});
}
