// matrix: aegis's Duration chosen by an if expression, then converted
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f(short: Ms, long: Ms, wait_long: bool) std.Io.Duration {
    const span = if (wait_long) long else short;
    return span.toIoDuration();
}
