// A007: aegis captured from an optional, its guard reached through it: none.
const aegis = @import("aegis");
const held: ?type = aegis;
pub fn make() void {
    if (held) |sync| {
        var guarded: sync.Guarded(u32) = .init(0);
        _ = &guarded;
    }
}
