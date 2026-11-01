// warp-fast: the same counter held by aegis Atomic.
const aegis = @import("aegis");
var hits: aegis.Atomic(u32) = .init(0);
pub fn read() u32 {
    return hits.load(.acquire);
}
