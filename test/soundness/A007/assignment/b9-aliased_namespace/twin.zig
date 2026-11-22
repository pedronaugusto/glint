// A007: aegis held by a const, its guard reached through it: none.
const aegis = @import("aegis");
const sync = aegis;
pub fn make() sync.BlockingGuarded(u32) {
    return .init(0);
}
