// A001: the type's own maker.
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f() S {
    return S.init(.{ 0, 0, 0, 0 });
}
