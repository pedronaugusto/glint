// glint-b: A015 branch (select): the same shape made safe, which must stay clean
const std = @import("std");
const File = std.Io.File;
pub fn pick(comptime T: type, c: bool, a: T, b: T) T {
    return if (c) a else b;
}
pub fn f(held: *const File, other: *const File, c: bool) File {
    return pick(File, c, held.*, other.*);
}
