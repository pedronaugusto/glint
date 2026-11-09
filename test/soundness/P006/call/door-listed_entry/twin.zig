// P006 call: a function `.door` lists does the replaced work itself: its raw call is the door's.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.syncAgain(file, io);
}
