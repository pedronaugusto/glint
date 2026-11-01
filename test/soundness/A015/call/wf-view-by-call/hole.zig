// warp-fast: a public generic called through @call hands back the file just opened: an owner handed over
const std = @import("std");
const File = std.Io.File;
pub fn pass(comptime T: type, v: T) T {
    return v;
}
pub fn f(dir: std.Io.Dir, io: std.Io) !File {
    return @call(.auto, pass, .{ File, try dir.openFile(io, "a", .{}) });
}
