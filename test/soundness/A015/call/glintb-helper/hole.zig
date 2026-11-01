// glint-b: A015 call (helper): the unsafe shape, which must flag
const std = @import("std");
const File = std.Io.File;
pub fn pass(comptime T: type, v: T) T {
    return v;
}
pub fn f(dir: std.Io.Dir, io: std.Io) !File {
    return pass(File, try dir.openFile(io, "a", .{}));
}
