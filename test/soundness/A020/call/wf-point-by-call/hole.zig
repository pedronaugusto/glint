// warp-fast: a loop with no bound whose only call through @call is to a function that never cancels
const std = @import("std");
fn step(n: u64) u64 {
    return n +% 1;
}
pub fn spin(io: std.Io) !void {
    _ = io;
    var n: u64 = 0;
    while (true) {
        n = @call(.auto, step, .{n});
    }
}
