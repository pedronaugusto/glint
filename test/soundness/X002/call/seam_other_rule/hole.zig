// a seam for another rule covers nothing of this one: the call is a finding.
const std = @import("std");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}
