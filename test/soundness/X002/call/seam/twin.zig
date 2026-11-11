// a seam the project declares for this file and this rule, with its reason: no finding (the
// report counts the seam and the site inside it).
const std = @import("std");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}
