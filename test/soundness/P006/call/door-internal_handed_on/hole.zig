// P006 call: the package stores the internal function in a public table, so whoever reads it calls it past the door.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.table.flush(file, io);
}
