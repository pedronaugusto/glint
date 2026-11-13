// A001: std.mem.bytesAsValue makes a pointer to a governed value out of the caller's bytes.
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f(b: *[4]u8) *S {
    return std.mem.bytesAsValue(S, b);
}
