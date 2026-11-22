// A011: aegis's Duration made by a decl literal: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f() Millis {
    return .fromRaw(1000);
}
