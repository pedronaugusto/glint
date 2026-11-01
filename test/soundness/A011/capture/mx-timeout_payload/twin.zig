// matrix: the captured Duration converted by aegis, rounding stated
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i64);
pub fn f(t: std.Io.Timeout) !Ms {
    return switch (t) {
        .duration => |d| try Ms.fromIoDuration(d.raw, .down),
        else => Ms.fromRaw(0),
    };
}
