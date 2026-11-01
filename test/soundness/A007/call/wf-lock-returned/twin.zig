// warp-fast: a function returns aegis Atomic by value, which holds its cell.
const aegis = @import("aegis");
pub fn make() aegis.Atomic(u32) {
    return .init(0);
}
