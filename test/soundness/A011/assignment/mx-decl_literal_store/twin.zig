// matrix: the milliseconds held as aegis's Duration, converted to std's by toIoDuration
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f(ms: Ms) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    d = ms.toIoDuration();
    return d;
}
