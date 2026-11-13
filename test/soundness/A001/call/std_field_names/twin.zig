// A001: the names of a type the program declares itself, read by the same helper.
const std = @import("std");
const aegis = @import("aegis");
const Plain = struct { a: u8, b: u8 };
pub fn f() usize {
    return std.meta.fieldNames(Plain).len;
}
