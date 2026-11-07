// The same, handed a file the caller holds.
const std = @import("std");
const File = std.Io.File;
pub fn wrap(comptime T: type, v: T) struct { T } {
    return .{v};
}
pub fn f(held: *const File) struct { File } {
    return wrap(File, held.*);
}
