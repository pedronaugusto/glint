// matrix: aegis's seconds converted to std's Duration, held by @as
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.units.Duration(.second, i32);
pub fn f(s: S) std.Io.Duration {
    const d = @as(std.Io.Duration, s.toIoDuration());
    return d;
}
