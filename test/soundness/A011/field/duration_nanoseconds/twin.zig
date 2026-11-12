// A011: aegis's Duration, which keeps its unit, is no finding.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(d: Millis) Millis {
    return d;
}
