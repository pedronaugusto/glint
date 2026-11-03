const std = @import("std");
pub fn f(d: *std.Io.Duration, e: *std.Io.Duration) void {
    std.mem.swap(std.Io.Duration, d, e);
}
