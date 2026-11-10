// P006 call: a private helper handed to a `comptime` parameter of the package's own function,
// which only calls it, is used by the function that hands it: reached from the door alone, its
// raw call is the door's.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.syncFile(file, io);
}
