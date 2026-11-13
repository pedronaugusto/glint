// A001: the helper hands the bytes to the type's own maker.
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
fn make(b: *const [4]u8) S {
    return S.init(b.*);
}
pub fn f(b: *const [4]u8) S {
    return make(b);
}
