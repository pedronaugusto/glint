// matrix: aegis's Duration inside a Timeout literal
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f(ms: Ms) std.Io.Timeout {
    return .{ .duration = .{ .raw = ms.toIoDuration(), .clock = .awake } };
}
