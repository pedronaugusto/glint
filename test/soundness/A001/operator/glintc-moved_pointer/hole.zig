// A001: a holder reached by a many-item pointer moved by a number, its internal field read: a
// finding.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(many: [*]const S) u32 {
    return (many + 1)[0].aegis_material;
}
