// A001: the type's own maker takes the bytes.
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f(b: [4]u8) S {
    return S.init(b);
}
