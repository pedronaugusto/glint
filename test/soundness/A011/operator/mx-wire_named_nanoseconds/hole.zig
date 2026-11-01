// matrix: std's raw nanoseconds compared with a peer's integer whose field is only named nanoseconds
const std = @import("std");
const Wire = struct { nanoseconds: i96 };
pub fn late(left: std.Io.Duration, w: Wire) bool {
    return left.nanoseconds < w.nanoseconds;
}
