// The same generic handed a file the caller holds: a view of it.
const std = @import("std");
const File = std.Io.File;
const Type = type;
pub fn pass(comptime U: Type, v: U) U {
    return v;
}
pub fn f(held: *const File) File {
    return pass(File, held.*);
}
