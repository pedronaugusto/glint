// matrix: std's Clock.Duration built by a struct literal from aegis's Duration
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f(ms: Ms) std.Io.Clock.Duration {
    return .{ .raw = ms.toIoDuration(), .clock = .awake };
}
