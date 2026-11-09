// P006 call: the same raw call in a file of the declaring package that none of its modules
// reaches (a benchmark's baseline): published to no one, so left.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
    try module.syncFile(file, io);
}
