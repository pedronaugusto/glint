// A001: std.mem.zeroes makes a governed type by reflection, past its makers (review 8, M5).
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f() S {
    return std.mem.zeroes(S);
}
