// A007: aegis the result of a labeled block, its guard reached through it: none.
const aegis = @import("aegis");
const sync = blk: {
    break :blk aegis;
};
pub fn make() sync.BlockingGuarded(u32) {
    return .init(0);
}
