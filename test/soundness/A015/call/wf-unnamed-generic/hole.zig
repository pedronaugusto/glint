// warp-fast: a generic called through a choice of holders hands an opened file over by value; which function it is does not resolve
const std = @import("std");
const File = std.Io.File;
const A = struct {
    pub fn pass(comptime T: type, v: T) T {
        return v;
    }
};
const B = struct {
    pub fn pass(comptime T: type, v: T) T {
        return v;
    }
};
pub fn f(dir: std.Io.Dir, io: std.Io, comptime first: bool) !File {
    return (if (first) A else B).pass(File, try dir.openFile(io, "a", .{}));
}
