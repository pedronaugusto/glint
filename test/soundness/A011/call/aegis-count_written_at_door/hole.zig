// case: a count named by a constant handed to a door of another unit: its unit is only in its name
const std = @import("std");
const timeout_ms = 300;
pub fn f(io: std.Io) !void {
    try io.sleep(.fromSeconds(timeout_ms), .awake);
}
