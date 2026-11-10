// P006 call: an import discarded where it is written hands the file's namespace to nobody, so
// its `pub fn` is still the package's alone and its raw call is the door's.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.syncFile(file, io);
}
