// warp-fast: a function returns aegis Atomic by value, which holds its cell.
const aegis = @import("aegis");
const Hits = enum(u32) { _ };
pub fn make() aegis.Atomic(Hits) {
    return .init(@enumFromInt(0));
}
