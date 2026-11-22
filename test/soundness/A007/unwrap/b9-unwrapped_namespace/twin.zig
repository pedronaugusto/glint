// A007: aegis unwrapped from an optional by .?, its guard reached through it: none.
const aegis = @import("aegis");
const held: ?type = aegis;
pub fn make() held.?.BlockingGuarded(u32) {
    return .init(0);
}
