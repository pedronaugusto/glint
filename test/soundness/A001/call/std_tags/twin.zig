// A001: the same helper over an enum the program declares itself.
const std = @import("std");
const aegis = @import("aegis");
const E = enum { a, b };
pub fn f() usize {
    return std.meta.tags(E).len;
}
