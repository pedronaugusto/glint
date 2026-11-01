// glint-b: A015 branch (select): the unsafe shape, which must flag
const std = @import("std");
const File = std.Io.File;
pub fn pick(comptime T: type, c: bool, a: T, b: T) T {
    return if (c) a else b;
}
pub fn f(dir: std.Io.Dir, io: std.Io, held: *const File, c: bool) !File {
    return pick(File, c, try dir.openFile(io, "a", .{}), held.*);
}
