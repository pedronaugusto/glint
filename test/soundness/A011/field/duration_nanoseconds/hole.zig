// A011: std's Duration read as a raw count of nanoseconds outside a seam.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(d: std.Io.Duration) i96 {
    return d.nanoseconds;
}
