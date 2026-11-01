// review 6: a15/o01_field_builtin_write.zig
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
// The same write through @field: the field is still given an owner.
pub fn store(s: *Stored, dir: std.Io.Dir, io: std.Io) !void {
    @field(s, "file") = try dir.openFile(io, "a", .{});
}
