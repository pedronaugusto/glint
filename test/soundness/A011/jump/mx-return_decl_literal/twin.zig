// matrix: aegis's Duration returned as std's, converted by toIoDuration
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f(ms: Ms) std.Io.Duration {
    return ms.toIoDuration();
}
