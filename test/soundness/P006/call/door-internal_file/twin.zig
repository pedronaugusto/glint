// P006 call: a `pub fn` of a file the package keeps to itself is public to the package alone,
// so its raw call is the door's when only the door reaches it.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.syncFile(file, io);
}
