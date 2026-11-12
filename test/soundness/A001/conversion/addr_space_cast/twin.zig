// A001: the pointer handed on as it is.
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f(p: *const S) *const S {
    return p;
}
