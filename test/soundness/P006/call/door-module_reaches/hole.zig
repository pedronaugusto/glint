// P006 call: a raw call the package replaces, in a file its module reaches and outside the door,
// is found: what no module reaches is left (door-no_module_reaches), what one reaches is not.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.stray(file, io);
}
