// A001: std.meta.fieldInfo reads a governed type's field by @typeInfo (review 8, M5).
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f() []const u8 {
    return std.meta.fieldInfo(S, .aegis_material).name;
}
