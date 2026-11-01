// glint-b: A015 unwrap (optional): the same shape made safe, which must stay clean
const std = @import("std");
const File = std.Io.File;
pub fn pass(comptime T: type, v: ?T) T {
    return v.?;
}
pub fn f(held: *const File) File {
    return pass(File, held.*);
}
