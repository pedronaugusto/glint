// replaces .decl: the package's answer is no finding.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.syncFile(file, io);
}
