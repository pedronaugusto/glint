// A001: the same helper over a type the program declares itself.
const std = @import("std");
const aegis = @import("aegis");
const Plain = struct { a: u8 };
pub fn f() []const u8 {
    return std.meta.fieldInfo(Plain, .a).name;
}
