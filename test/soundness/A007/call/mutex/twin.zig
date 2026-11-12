// A007: aegis's guard, which holds the data it guards, is no finding.
const aegis = @import("aegis");
pub fn make() aegis.BlockingGuarded(u32) {
    return .init(0);
}
