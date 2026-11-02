// warp-fast: the same counter held by aegis Atomic.
const aegis = @import("aegis");
const Hits = enum(u32) { _ };
var hits: aegis.Atomic(Hits) = .init(@enumFromInt(0));
pub fn read() Hits {
    return hits.load(.acquire);
}
