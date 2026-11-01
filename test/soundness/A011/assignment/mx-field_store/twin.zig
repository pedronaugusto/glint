// matrix: the span added as aegis's Duration and converted once
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f(base: Ms, more: Ms) !std.Io.Duration {
    const total = try base.add(more);
    return total.toIoDuration();
}
