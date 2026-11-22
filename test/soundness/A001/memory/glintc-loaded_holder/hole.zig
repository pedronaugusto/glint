// A001: a holder an atomic load reads out of memory, its internal field read: a finding.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(slot: *const *const S) u32 {
    const held = @atomicLoad(*const S, slot, .acquire);
    return held.aegis_material;
}
