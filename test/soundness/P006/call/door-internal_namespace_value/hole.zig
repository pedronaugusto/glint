// P006 call: the internal namespace leaves through a second name, so its functions are the outside's.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.outside.flush(file, io);
}
