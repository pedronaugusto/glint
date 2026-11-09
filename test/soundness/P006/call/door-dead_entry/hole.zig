// P006 call: a `.door` entry that reaches no call the package replaces is found where the list
// names it: the list cannot grow into an allowlist.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.syncFile(file, io);
    module.idle();
}
