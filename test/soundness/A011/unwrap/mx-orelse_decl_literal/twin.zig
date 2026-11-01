// matrix: aegis's default converted on orelse's right
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f(left: ?std.Io.Duration, default: Ms) std.Io.Duration {
    return left orelse default.toIoDuration();
}
