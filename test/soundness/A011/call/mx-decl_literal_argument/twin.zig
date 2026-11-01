// matrix: aegis's Duration handed to std's sleep, converted by toIoDuration
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f(io: std.Io, ms: Ms) !void {
    try io.sleep(ms.toIoDuration(), .awake);
}
