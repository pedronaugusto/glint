// matrix: aegis's conversion pair taken out of a tuple by a destructure
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f(ms: Ms) std.Io.Duration {
    const span, const extra = .{ ms, @as(u8, 0) };
    _ = extra;
    return span.toIoDuration();
}
