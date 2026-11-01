// matrix: aegis's Duration read in a function taking it as anytype
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i64);
fn span(d: anytype) std.Io.Duration {
    return d.toIoDuration();
}
pub fn f(d: Ms) std.Io.Duration {
    return span(d);
}
