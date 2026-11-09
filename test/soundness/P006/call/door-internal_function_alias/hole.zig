// P006 call: a public alias names the internal function, so the outside calls it past the door.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.flush(file, io);
}
