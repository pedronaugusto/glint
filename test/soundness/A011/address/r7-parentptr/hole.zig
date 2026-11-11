const std = @import("std");
// std's Duration made over a raw count by @fieldParentPtr.
pub fn f(raw: *i96) *std.Io.Duration {
    return @fieldParentPtr("nanoseconds", raw);
}
