// case: a count written out in the call: the door's own name is its unit
const std = @import("std");
pub fn f(io: std.Io) !void {
    try io.sleep(.fromSeconds(5), .awake);
    try io.sleep(.fromMilliseconds(2 * 60), .awake);
}
