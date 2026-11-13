// A001: a helper of the program's own that casts a byte parameter to a governed pointer.
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
fn view(b: *[4]u8) *S {
    return @ptrCast(b);
}
pub fn f(b: *[4]u8) *S {
    return view(b);
}
