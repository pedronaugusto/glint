// A001: governed values sorted by the caller's comparator, which uses the type's own compare: std's sort only moves them.
const aegis = @import("aegis");
const std = @import("std");
const Ms = aegis.units.Duration(.millisecond, u64);
fn earlier(_: void, a: Ms, b: Ms) bool {
    return a.compare(b) == .lt;
}
pub fn order(xs: []Ms) void {
    std.mem.sort(Ms, xs, {}, earlier);
}
