// A001: the value made through Secret's API: none.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(v: u32) S {
    return .init(v);
}
