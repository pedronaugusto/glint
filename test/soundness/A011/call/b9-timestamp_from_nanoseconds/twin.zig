// A011: a duration made from a raw count by aegis's Duration, which keeps its unit: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn at(n: i64) Millis {
    return Millis.fromRaw(n);
}
