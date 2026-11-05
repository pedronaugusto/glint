// A generic whose result is its type parameter's value, bound with `type`: `Id(type, File)` is the
// type File, so f returns an opened file by value.
const std = @import("std");
pub fn Id(comptime T: type, comptime v: T) T {
    return v;
}
const Held = Id(type, std.Io.File);
pub fn f(dir: std.Io.Dir, io: std.Io) !Held {
    return dir.openFile(io, "a", .{});
}
