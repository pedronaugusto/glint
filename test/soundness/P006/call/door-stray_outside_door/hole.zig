// P006 call: a package's `.door` covers the functions it lists: a public function outside it
// that makes the same raw call stays found.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.stray(file, io);
}
