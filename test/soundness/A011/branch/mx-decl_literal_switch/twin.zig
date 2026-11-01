// matrix: aegis's Durations converted in a switch's prongs
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
const S = aegis.units.Duration(.second, i32);
pub fn f(ms: Ms, s: S, unit: enum { ms, s }) std.Io.Duration {
    return switch (unit) {
        .ms => ms.toIoDuration(),
        .s => s.toIoDuration(),
    };
}
