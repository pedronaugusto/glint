// A001: a holder an atomic load reads out of memory, read through Secret's API: none.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(slot: *const *const S) u32 {
    const held = @atomicLoad(*const S, slot, .acquire);
    return held.expose().*;
}
