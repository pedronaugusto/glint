// matrix: std's Duration out of an optional by .?, converted by aegis
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i64);
pub fn f(left: ?std.Io.Duration) !Ms {
    return Ms.fromIoDuration(left.?, .down);
}
