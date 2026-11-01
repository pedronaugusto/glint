// matrix: aegis's Duration converted in a defer, at the scope's exit
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f(out: *std.Io.Duration, ms: Ms) void {
    defer out.* = ms.toIoDuration();
}
