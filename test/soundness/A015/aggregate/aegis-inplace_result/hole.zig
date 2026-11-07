// A public generic whose result is a struct written in place holding T: bound with File, it hands the opened file back by value inside it.
const std = @import("std");
const File = std.Io.File;
pub fn wrap(comptime T: type, v: T) struct { T } {
    return .{v};
}
pub fn f(dir: std.Io.Dir, io: std.Io) !struct { File } {
    return wrap(File, try dir.openFile(io, "a", .{}));
}
