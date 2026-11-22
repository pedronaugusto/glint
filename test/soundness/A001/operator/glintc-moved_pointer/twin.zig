// A001: a holder reached by a many-item pointer moved by a number, read through Secret's API:
// none.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(many: [*]const S) u32 {
    return (many + 1)[0].expose().*;
}
