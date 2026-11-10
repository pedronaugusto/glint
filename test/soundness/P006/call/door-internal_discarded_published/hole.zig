// P006 call: a discard of the import beside it clears nothing: the module still publishes the
// file, so its pub functions are API, not the package's alone.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.sys.flush(file, io);
}
