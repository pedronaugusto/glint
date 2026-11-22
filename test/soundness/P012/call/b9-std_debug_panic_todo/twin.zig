// P012: std's panic function given a message naming a state the program reached.
const std = @import("std");
pub fn g(n: usize) void {
    std.debug.panic("index {d} out of range", .{n});
}
