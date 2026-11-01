// matrix: aegis's Duration stored through a pointer to std's Duration
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f(out: *std.Io.Duration, ms: Ms) void {
    const p = out;
    p.* = ms.toIoDuration();
}
