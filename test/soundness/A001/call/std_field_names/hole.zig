// A001: std.meta.fieldNames reads a governed type's fields by @typeInfo on the type it is handed
// (review 8, M5: std.meta.fields is a @compileError on Zig 0.17; its live helpers are these).
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f() usize {
    return std.meta.fieldNames(S).len;
}
