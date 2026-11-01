// matrix: aegis's Duration the result of a labeled block, then converted
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f(ms: Ms, twice: bool) !std.Io.Duration {
    const span = blk: {
        if (twice) break :blk try ms.mul(2);
        break :blk ms;
    };
    return span.toIoDuration();
}
