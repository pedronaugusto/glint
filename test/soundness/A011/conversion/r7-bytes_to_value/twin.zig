// A Duration's own bytes read back as a Duration.
const std = @import("std");
pub fn f(d: std.Io.Duration) std.Io.Duration {
    return std.mem.bytesToValue(std.Io.Duration, std.mem.asBytes(&d));
}
