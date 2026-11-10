// P006 call: an enum literal spelled like a private function (`.flushed` beside `fn flushed`)
// is no use of the function: it is still only called, and only the door reaches it.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.syncFile(file, io);
}
