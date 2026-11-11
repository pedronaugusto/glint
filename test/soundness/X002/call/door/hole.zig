// replaces .door: where an entry names its door, the package's own use outside it is found in
// the package (module.zig's syncAgain); this file only calls the package.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.syncAgain(file, io);
}
