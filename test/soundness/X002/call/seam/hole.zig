// a seam is for the file and rule it names: this file is no seam, so the call is a finding.
const std = @import("std");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}
