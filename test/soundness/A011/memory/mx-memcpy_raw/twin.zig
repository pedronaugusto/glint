// matrix: one of std's Durations copied into another by @memcpy: no raw count crosses
const std = @import("std");
pub fn f(from: std.Io.Duration) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    @memcpy(std.mem.asBytes(&d), std.mem.asBytes(&from));
    return d;
}
