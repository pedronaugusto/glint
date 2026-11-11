const std = @import("std");
// std's Group holds an atomic.Value by value; a local copy of one the caller lends.
pub fn f(g: *std.Io.Group) void {
    var copy = g.*;
    _ = &copy;
}
