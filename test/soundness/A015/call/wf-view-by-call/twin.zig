// warp-fast: the same generic through @call handed a file the caller holds: a view of it
const std = @import("std");
const File = std.Io.File;
pub fn pass(comptime T: type, v: T) T {
    return v;
}
pub fn f(held: *const File) File {
    return @call(.auto, pass, .{ File, held.* });
}
