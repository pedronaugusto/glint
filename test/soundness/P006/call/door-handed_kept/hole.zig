// P006 call: the function the helper is handed to keeps it where a later call takes it from,
// so the helper is no longer used by the one that hands it alone: its raw call is reached
// outside the door.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.again(file, io);
}
