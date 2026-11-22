// P012: std's panic function given a message that marks the code unfinished.
const std = @import("std");
pub fn g() void {
    std.debug.panic("TODO: finish", .{});
}
