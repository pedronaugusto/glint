// P006 call: a private helper handed to a function outside the package is used by the function
// that hands it: outside code cannot name it, so that hand is its only route, and only the
// door reaches the hander.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.syncFile(file, io);
}
