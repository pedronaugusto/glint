// matrix: std's Duration narrowed by aegis's checked conversion
const std = @import("std");
const aegis = @import("aegis");
const Ns = aegis.units.Duration(.nanosecond, u64);
pub fn f(d: std.Io.Duration) !Ns {
    return Ns.fromIoDuration(d, .exact);
}
